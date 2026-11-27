#!/bin/sh
set -eu

service=$1
port=$2
source_cidr=${3:-}

network=$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" \
    --query 'cluster.resourcesVpcConfig' --output json)
group=$(printf '%s\n' "$network" | jq -er '.clusterSecurityGroupId | select(startswith("sg-"))')

if [ -z "$source_cidr" ]; then
    vpc=$(printf '%s\n' "$network" | jq -er '.vpcId | select(startswith("vpc-"))')
    source_cidr=$(aws ec2 describe-vpcs --region "$AWS_REGION" --vpc-ids "$vpc" \
        --query 'Vpcs[0].CidrBlock' --output text)
    printf 'Using the primary IPv4 CIDR of EKS VPC %s for %s ingress.\n' "$vpc" "$service"
fi

cidr=$(python3 - "$source_cidr" <<'PY'
import ipaddress
import sys

try:
    network = ipaddress.IPv4Network(sys.argv[1], strict=True)
    if network.prefixlen == 0:
        raise ValueError
except ValueError:
    sys.exit("Use a specific IPv4 CIDR for NodePort access, such as your public IP followed by /32.")

print(network)
PY
)
description="Pathnex $service NodePort"
rules=$(aws ec2 describe-security-group-rules --region "$AWS_REGION" \
    --filters "Name=group-id,Values=$group" --output json)
previous=$(printf '%s\n' "$rules" | jq -c --arg description "$description" '
    [.SecurityGroupRules[] | select(.IsEgress == false and .Description == $description)]
    | if length > 1 then error("Multiple matching Pathnex NodePort security group rules") else .[0] end')
matching=$(printf '%s\n' "$rules" | jq --arg cidr "$cidr" --argjson port "$port" '
    any(.SecurityGroupRules[]; .IsEgress == false and .IpProtocol == "tcp"
        and .FromPort == $port and .ToPort == $port and .CidrIpv4 == $cidr)')

if [ "$previous" != null ]; then
    if printf '%s\n' "$previous" | jq -e --arg cidr "$cidr" --argjson port "$port" \
        '.IpProtocol == "tcp" and .FromPort == $port and .ToPort == $port and .CidrIpv4 == $cidr' > /dev/null; then
        echo "$service ingress already configured on $group."
        exit 0
    fi
    if [ "$matching" = true ]; then
        echo "Remove the overlapping manual rule before updating the pipeline-managed NodePort ingress." >&2
        exit 1
    fi
    changes=$(printf '%s\n' "$previous" | jq -c --arg cidr "$cidr" --argjson port "$port" '
        [{SecurityGroupRuleId, SecurityGroupRule: {
            IpProtocol: "tcp", FromPort: $port, ToPort: $port, CidrIpv4: $cidr, Description
        }}]')
    aws ec2 modify-security-group-rules --region "$AWS_REGION" --group-id "$group" \
        --security-group-rules "$changes" > /dev/null
elif [ "$matching" = false ]; then
    permissions=$(jq -cn --arg cidr "$cidr" --argjson port "$port" --arg description "$description" '
        [{IpProtocol: "tcp", FromPort: $port, ToPort: $port,
          IpRanges: [{CidrIp: $cidr, Description: $description}]}]')
    aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$group" \
        --ip-permissions "$permissions" > /dev/null
fi

printf '%s ingress allows TCP %s from %s on %s.\n' "$service" "$port" "$cidr" "$group"
