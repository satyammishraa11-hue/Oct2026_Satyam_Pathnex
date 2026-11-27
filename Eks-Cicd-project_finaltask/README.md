# Pathnex EKS Practical on GitLab CI/CD

This practical deploys the Pathnex application and a Prometheus, Grafana, and
Alertmanager monitoring stack on Amazon EKS. GitLab CI/CD:

1. Tests and builds the Python application.
2. Pushes the container image by digest to GitLab Container Registry.
3. Plans and applies the Terraform infrastructure.
4. Deploys Pathnex with Helm.
5. Deploys the Kubernetes monitoring stack with Helm.
6. Opens controlled AWS NodePort access.
7. Provides a manual pipeline action to destroy the lab.

## Lab Configuration

| Setting | Default |
| --- | --- |
| AWS region | `ap-south-1` |
| EKS cluster | `pathnex-gitlab-staging` |
| Kubernetes version | `1.35` |
| Node group | `pathnex-ng`, one Spot `c7i-flex.large` node, maximum two nodes |
| Application namespace | `pathnex` |
| Monitoring namespace | `pathnex-monitoring` |
| Pathnex NodePort | `30081` |
| Grafana NodePort | `30080` |

Terraform reads the AWS account's default VPC and its available subnets. The
default VPC must have subnets in at least two Availability Zones.

> EKS and EC2 resources incur AWS charges. Run the destroy workflow when the
> practical is complete.

## Prerequisites

Install or prepare access to:

- GitLab project on `main`
- AWS account with permissions to manage EKS, EC2, IAM, and S3
- AWS IAM OIDC identity provider for `https://gitlab.com`
- GitLab deploy token with `read_registry`
- Terraform backend S3 bucket
- GitLab-hosted runner
- AWS CLI and `kubectl` for local verification

## 1. Protect the GitLab Branch

In GitLab:

1. Set `main` as the default branch.
2. Add a branch rule for `main`.
3. Confirm hosted runners are enabled.
4. Confirm the project's Container Registry is enabled.

The infrastructure and deploy jobs run only on protected `main` commits.

## 2. Create the Terraform State Bucket

Create a private S3 bucket in or accessible from the deployment region.
Enable:

- Block all public access
- Bucket versioning
- Default encryption

Use this backend key:

```text
pathnex/staging/terraform.tfstate
```

The Terraform CI backend lock key is:

```text
pathnex/staging/terraform.tfstate.tflock
```

The CI role needs at minimum:

- `s3:ListBucket` on the bucket
- `s3:GetObject`, `s3:PutObject`, and `s3:DeleteObject` on the state object
- `s3:GetObject`, `s3:PutObject`, and `s3:DeleteObject` on the lock object

## 3. Configure AWS OIDC

Create an AWS IAM OIDC identity provider:

```text
Provider URL: https://gitlab.com
Audience: sts.amazonaws.com
```

Create an IAM role such as `pathnex-gitlab-terraform`. Replace the account ID
and project path in this example trust policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::123456789012:oidc-provider/gitlab.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "gitlab.com:aud": "sts.amazonaws.com",
          "gitlab.com:sub": "project_path:YOUR_NAMESPACE/pathnex-eks-gitlab:ref_type:branch:ref:main"
        }
      }
    }
  ]
}
```

Attach permissions that allow the role to manage the resources declared in
`*.tf`, including:

- Read access for the default VPC and subnets
- EKS cluster, managed node group, add-on, and Pod Identity operations
- Creation and attachment of the IAM roles in `iam.tf`
- `iam:PassRole` for the lab roles
- S3 access to the exact backend state and lock objects
- EC2 discovery and cluster security-group rule updates
- Kubernetes access for Helm, Services, namespaces, secrets, and monitoring

The pipeline uses the cluster creator identity for initial Kubernetes access.
When using an existing cluster created by a different identity, add the CI
role to the EKS access configuration before deployment.

## 4. Create the GitLab Registry Deploy Token

In **Settings > Repository > Deploy tokens**, create a project deploy token:

- Name: `pathnex-eks-pull`
- Scope: `read_registry`
- Set a suitable expiration date

Save the generated username and token value. The token value is displayed only
once.

## 5. Configure GitLab CI/CD Variables

In **Settings > CI/CD > Variables**, add protected variables.

| Variable | Required | Purpose |
| --- | --- | --- |
| `AWS_ROLE_ARN` | Yes | ARN of the OIDC deployment role |
| `TF_STATE_BUCKET` | Yes | Private S3 bucket name without `s3://` |
| `PATHNEX_REGISTRY_USER` | Yes | Deploy token username |
| `PATHNEX_REGISTRY_TOKEN` | Yes | Deploy token value |
| `TF_STATE_REGION` | Optional | State bucket region if different from `AWS_REGION` |
| `AWS_REGION` | Optional | AWS region; defaults to `ap-south-1` |
| `EKS_CLUSTER_NAME` | Optional | Cluster name; defaults to `pathnex-gitlab-staging` |
| `PATHNEX_NAMESPACE` | Optional | Application namespace |
| `PATHNEX_MONITORING_NAMESPACE` | Optional | Monitoring namespace |
| `PATHNEX_APP_NODE_PORT` | Optional | Application NodePort; defaults to `30081` |
| `PATHNEX_APP_SOURCE_CIDR` | Optional | Trusted IPv4 CIDR for application access |
| `PATHNEX_GRAFANA_NODE_PORT` | Optional | Grafana NodePort; defaults to `30080` |
| `PATHNEX_GRAFANA_SOURCE_CIDR` | Optional | Trusted IPv4 CIDR for Grafana access |

Do not add quotes or the `s3://` prefix to variable values. Mask and protect
`PATHNEX_REGISTRY_TOKEN`.

For `*SOURCE_CIDR`, use a specific network:

```text
Public IPv4: 203.0.113.25/32
VPC network: 172.31.0.0/16
```

A `/0` CIDR is not accepted for NodePort exposure.

## 6. Push the Repository

Before pushing, review the repository and exclude Terraform state, plans,
credentials, and local variable files.

```bash
git status --short
git diff --stat

git add .
git diff --cached --name-only
git commit -m "Add Pathnex EKS deployment practical"
git push -u origin main
```

GitLab will run the pipeline automatically for protected `main`. A pipeline
can also be started manually from **Build > Pipelines**.

## 7. Follow the Pipeline

| Job | Expected result |
| --- | --- |
| `pathnex:test` | Runs the Python unit tests |
| `pathnex:build` | Builds and pushes the image to the GitLab Container Registry |
| `pathnex:aws_identity` | Optional manual AWS STS identity check |
| `pathnex:terraform_plan` | Validates and saves a Terraform plan |
| `pathnex:terraform_review` | Opens a review child pipeline when infrastructure changes exist |
| `pathnex:terraform_finalize` | Applies the reviewed plan or skips apply when unchanged |
| `pathnex:deploy_staging` | Verifies the registry image and deploys it with Helm |
| `pathnex:deploy_monitoring` | Deploys kube-prometheus-stack |
| `pathnex:expose_pathnex` | Opens the application NodePort in the EKS cluster security group |
| `pathnex:expose_grafana` | Creates and opens the Grafana NodePort |

For infrastructure changes, open the review child pipeline and run
`pathnex:approve_terraform_apply`. The parent pipeline then applies the saved
plan. Terraform plan exit code `0` skips apply automatically.

## 8. Local Cluster Verification

Use an AWS identity with an EKS access entry or another authorized Kubernetes
identity:

```bash
aws sts get-caller-identity

aws eks update-kubeconfig \
  --region ap-south-1 \
  --name pathnex-gitlab-staging

kubectl get nodes
kubectl get pods -A
helm list -A
```

Verify the application:

```bash
kubectl -n pathnex get deployment,pod,service
kubectl -n pathnex get pod -l app.kubernetes.io/instance=pathnex
kubectl -n pathnex rollout status deployment/pathnex
```

Verify monitoring:

```bash
kubectl -n pathnex-monitoring get deployment,pod,service
helm -n pathnex-monitoring list
```

Find reachable node addresses:

```bash
kubectl get nodes -o wide
kubectl -n pathnex get service pathnex \
  -o jsonpath='{.spec.ports[0].nodePort}{"\n"}'
kubectl -n pathnex-monitoring get service pathnex-grafana-nodeport
```

Open:

```text
http://<reachable-node-ip>:30081/
http://<reachable-node-ip>:30080
```

The default source rule is the primary IPv4 CIDR of the EKS VPC. For direct
internet access, set the relevant `*_SOURCE_CIDR` variable to the public IP
with `/32` and use a reachable public node address.

## 9. Grafana Access

Grafana is created by kube-prometheus-stack with the service name
`pathnex-monitoring-grafana`. The pipeline creates the NodePort Service
`pathnex-grafana-nodeport`.

Sign in as `admin`. Read the generated password:

```bash
kubectl -n pathnex-monitoring get secret pathnex-monitoring-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d
echo
```

The monitoring stack collects cluster metrics. Pathnex-specific application
metrics require instrumentation and a Kubernetes `ServiceMonitor`.

## 10. Run the Stress Workloads

The repository includes [cpu-stress.yaml](./cpu-stress.yaml) and
[memory-stress.yaml](./memory-stress.yaml). The pipeline does not deploy them
automatically, because they can consume significant cluster capacity.

Create the namespace and deploy the workloads manually:

```bash
kubectl create namespace monitoring-lab

kubectl apply -f cpu-stress.yaml
kubectl apply -f memory-stress.yaml

kubectl -n monitoring-lab get deployment,pod
```

Observe CPU and memory use in Grafana and review pod scheduling:

```bash
kubectl -n monitoring-lab get pods -o wide
kubectl -n monitoring-lab describe pod
kubectl top nodes
kubectl top pods -A
```

Remove the workloads after the exercise:

```bash
kubectl delete -f cpu-stress.yaml
kubectl delete -f memory-stress.yaml
kubectl delete namespace monitoring-lab
```

## 11. Troubleshooting

### Protected variables are missing

Confirm the variable type, exact key, **All** environment scope, and
**Protected** setting. Variable values are not shared by GitLab with
unprotected branches.

### AWS OIDC identity fails

Check:

- OIDC provider URL and `sts.amazonaws.com` audience
- IAM role ARN
- Exact GitLab project path
- Branch subject containing `ref:main`
- Role trust policy and permissions

Test manually with the optional `pathnex:aws_identity` job.

### Registry returns 401 or 403

Confirm that:

- Both registry values come from the same deploy token
- The token has `read_registry`
- The token has not expired
- `PATHNEX_REGISTRY_USER` is not set to the GitLab user instead of the deploy
  token username

### NodePort is inaccessible

Confirm:

- The NodePort service has been created
- The node is reachable
- The cluster security group includes the configured `/32` or CIDR
- A network firewall or route does not block the port
- The EC2 role has discovery and security-group update permissions

### Node or pod is pending

Review events and capacity:

```bash
kubectl get nodes
kubectl get pods -A
kubectl get events -A --sort-by=.metadata.creationTimestamp
kubectl describe pod <pod-name> -n <namespace>
```

The managed node group uses Spot capacity. A Spot interruption can replace a
node, and a one-node lab may temporarily lose running pods.

### Terraform wants to replace the cluster

Stop before approving apply and verify:

- The S3 backend bucket and region
- The exact state key
- `EKS_CLUSTER_NAME`
- The AWS region
- Existing AWS resources

Do not approve a plan that recreates infrastructure unless that is intentional.

## 12. Destroy the Lab

Open the latest successful deployment pipeline on protected `main`. In the
**destroy** stage, run `pathnex:destroy_lab`.

The teardown child pipeline:

1. Creates a Terraform destroy plan.
2. Deletes the lab Grafana NodePort Service.
3. Uninstalls both Helm releases.
4. Applies the Terraform destroy plan.

Monitor `pathnex:terraform_destroy` until it succeeds.

The destroy workflow does not delete:

- The S3 state bucket
- The GitLab OIDC identity provider
- The GitLab project
- The GitLab deploy token

Before retrying destroy, remove any lab-owned `LoadBalancer` Services or
Ingress resources:

```bash
kubectl get svc,ingress -A
```

After cleanup, confirm the cluster and node group are absent:

```bash
aws eks describe-cluster \
  --region ap-south-1 \
  --name pathnex-gitlab-staging

aws ec2 describe-instances \
  --region ap-south-1 \
  --filters "Name=tag:eks:nodegroup-name,Values=pathnex-ng"
```

Revoke the registry deploy token when it is no longer required.

## Local Development

Run Python tests:

```bash
python3 -m unittest discover -s pathnex -v
```

Run the API locally:

```bash
python3 pathnex/server.py
curl -fsS http://127.0.0.1:8080/
```

Build the container:

```bash
docker build -t pathnex:local pathnex
```

Lint and render the application chart:

```bash
helm lint deploy/pathnex
helm template pathnex deploy/pathnex
```

## Project Layout

| Path | Purpose |
| --- | --- |
| `.gitlab-ci.yml` | GitLab stages and deployment jobs |
| `ci/` | Terraform review, NodePort, and destroy helper scripts |
| `*.tf` | EKS, IAM, node group, add-on, provider, and Terraform state configuration |
| `terraform.tfvars.example` | Example Terraform variable values |
| `pathnex/` | Python API, unit tests, and Dockerfile |
| `deploy/pathnex/` | Application Helm chart |
| `deploy/monitoring/values.yaml` | Monitoring Helm values |
| `cpu-stress.yaml` | Optional CPU stress deployment |
| `memory-stress.yaml` | Optional memory stress deployment |
