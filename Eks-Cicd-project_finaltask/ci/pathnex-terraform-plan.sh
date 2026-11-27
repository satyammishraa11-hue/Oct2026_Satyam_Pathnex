#!/bin/sh
set -eu

result=0
terraform plan -detailed-exitcode -lock-timeout=5m -out=pathnex.tfplan || result=$?

case "$result" in
    0)
        cat > pathnex-terraform-review.yml <<'YAML'
pathnex:no_terraform_changes:
  image: alpine:3.23
  script:
    - echo "Terraform found no infrastructure changes."
YAML
        ;;
    2)
        cat > pathnex-terraform-review.yml <<'YAML'
pathnex:approve_terraform_apply:
  image: alpine:3.23
  when: manual
  allow_failure: false
  manual_confirmation: "Apply the Terraform plan reviewed in the parent pipeline?"
  script:
    - echo "Terraform apply approved."
YAML
        ;;
    *)
        exit "$result"
        ;;
esac

printf '%s\n' "$result" > pathnex-plan-result
