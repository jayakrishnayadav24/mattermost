# Mattermost → EC2, deployed by GitHub Actions (Terraform + Ansible over SSM)

This repo provisions an EC2 host with **Terraform** and deploys **Mattermost** (MySQL +
Mattermost app + Nginx, all Docker containers) with **Ansible**. The pipeline connects to the
instance through **AWS Session Manager (SSM)** — no SSH key is stored anywhere — and authenticates
to AWS using **GitHub OIDC** (no long-lived access keys).

```
git push → GitHub Actions
            ├─ OIDC → assume AWS role (short-lived creds)
            ├─ terraform apply        (VPC, SG[22,80], SSM role, Ubuntu 24.04 EC2)
            ├─ wait for SSM online
            └─ ansible-playbook (over SSM): install Docker, run containers
                      ↓
        http://<public-ip>  →  Nginx :80 → Mattermost :8065 → MySQL :3306
```

## Layout

```
.
├── .github/workflows/deploy.yml   # OIDC → terraform → ansible (SSM)
├── terraform/                     # idempotent infra (S3 remote state)
│   ├── main.tf  variables.tf  outputs.tf  backend.tf
│   └── terraform.tfvars.example
├── ansible/
│   ├── playbook.yml  inventory.yml  ansible.cfg  requirements.yml
│   └── files/nginx/mattermost.conf
├── .gitignore
└── mattermost.md                  # the manual Docker-on-Ubuntu guide
```

---

## One-time AWS setup

You create these **once**, by hand (or a separate bootstrap), because the pipeline needs them to
exist before it can run.

### 1. S3 buckets

```bash
# Terraform remote state (keeps runs idempotent)
aws s3 mb s3://my-mattermost-tfstate --region ap-south-1

# File-transfer bucket used by the aws_ssm Ansible connection plugin
aws s3 mb s3://my-mattermost-ssm-transfer --region ap-south-1
```

### 2. GitHub OIDC provider + IAM role

Create the OIDC identity provider (once per account):

- Provider URL: `https://token.actions.githubusercontent.com`
- Audience: `sts.amazonaws.com`

Create an IAM role the workflow assumes. Its **trust policy** must restrict to your repo:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
      "StringLike":   { "token.actions.githubusercontent.com:sub": "repo:jayakrishnayadav24/mattermost:ref:refs/heads/main" }
    }
  }]
}
```

The role also needs a **permissions policy** — the pipeline creates the EC2 and all its
supporting infrastructure, so without this `terraform apply` fails with `AccessDenied`. Attach
this policy to the role (broad for first-run simplicity; tighten `Resource` and conditions for
production):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "TerraformInfra",
      "Effect": "Allow",
      "Action": [
        "ec2:RunInstances", "ec2:TerminateInstances", "ec2:StartInstances", "ec2:StopInstances",
        "ec2:Describe*", "ec2:GetConsoleOutput",
        "ec2:CreateTags", "ec2:DeleteTags",
        "ec2:CreateVpc", "ec2:DeleteVpc", "ec2:ModifyVpcAttribute",
        "ec2:CreateSubnet", "ec2:DeleteSubnet", "ec2:ModifySubnetAttribute",
        "ec2:CreateInternetGateway", "ec2:DeleteInternetGateway",
        "ec2:AttachInternetGateway", "ec2:DetachInternetGateway",
        "ec2:CreateRouteTable", "ec2:DeleteRouteTable",
        "ec2:CreateRoute", "ec2:DeleteRoute",
        "ec2:AssociateRouteTable", "ec2:DisassociateRouteTable",
        "ec2:CreateSecurityGroup", "ec2:DeleteSecurityGroup",
        "ec2:AuthorizeSecurityGroupIngress", "ec2:AuthorizeSecurityGroupEgress",
        "ec2:RevokeSecurityGroupIngress", "ec2:RevokeSecurityGroupEgress",
        "ec2:ModifyInstanceAttribute",
        "ec2:AssociateIamInstanceProfile", "ec2:DisassociateIamInstanceProfile",
        "iam:CreateRole", "iam:DeleteRole", "iam:GetRole",
        "iam:TagRole", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
        "iam:AttachRolePolicy", "iam:DetachRolePolicy",
        "iam:PutRolePolicy", "iam:GetRolePolicy", "iam:DeleteRolePolicy",
        "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile",
        "iam:GetInstanceProfile",
        "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile"
      ],
      "Resource": "*"
    },
    {
      "Sid": "PassSsmRoleToEc2Only",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::<ACCOUNT_ID>:role/mattermost-ssm-role",
      "Condition": {
        "StringEquals": { "iam:PassedToService": "ec2.amazonaws.com" }
      }
    },
    {
      "Sid": "TerraformState",
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": [
        "arn:aws:s3:::<TF_STATE_BUCKET>",
        "arn:aws:s3:::<TF_STATE_BUCKET>/*",
        "arn:aws:s3:::<SSM_BUCKET>",
        "arn:aws:s3:::<SSM_BUCKET>/*"
      ]
    },
    {
      "Sid": "AnsibleOverSSM",
      "Effect": "Allow",
      "Action": [
        "ssm:SendCommand",
        "ssm:StartSession",
        "ssm:TerminateSession",
        "ssm:ResumeSession",
        "ssm:DescribeInstanceInformation",
        "ssm:DescribeSessions",
        "ssm:GetCommandInvocation",
        "ssm:ListCommandInvocations"
      ],
      "Resource": "*"
    }
  ]
}
```

Notes:
- The EC2 actions are the explicit set Terraform needs to create/destroy the VPC, subnet, IGW,
  route table, security group, and instance (no `ec2:*` wildcard). If you extend `main.tf` with
  new resource types, add the matching actions.
- `iam:PassRole` is scoped to the single `mattermost-ssm-role` and restricted to EC2 via the
  `iam:PassedToService` condition — never use `PassRole` on `"*"` (it would let the role pass any
  role to any service). This matches `name_prefix = "mattermost"`; if you change the prefix,
  update the role name in the ARN.
- Replace `<ACCOUNT_ID>`, `<TF_STATE_BUCKET>`, and `<SSM_BUCKET>` with your real values.

### 3. GitHub repo configuration

Under **Settings → Secrets and variables → Actions**:

**Variables** (not secret):

| Name | Example |
|------|---------|
| `AWS_ROLE_ARN` | `arn:aws:iam::<ACCOUNT_ID>:role/mattermost-gha-oidc` |
| `AWS_REGION` | `ap-south-1` |
| `TF_STATE_BUCKET` | `my-mattermost-tfstate` |
| `SSM_BUCKET` | `my-mattermost-ssm-transfer` |

**Secrets**:

| Name | Purpose |
|------|---------|
| `MM_ROOT_PW` | MySQL root password |
| `MM_DB_PW` | MySQL app-user (`mmuser`) password |

> Also set the real state-bucket name in `terraform/backend.tf` (or rely on the
> `-backend-config` flags the workflow passes at init — both are wired up).

---

## Run it

```bash
git add .
git commit -m "Deploy Mattermost via SSM"
git push origin main
```

Or trigger manually: **Actions → Deploy Mattermost to EC2 (SSM) → Run workflow**.

When it finishes, the run **Summary** shows the instance ID and the URL. Open
`http://<public-ip>` and create the first admin account.

## Idempotency

- **Terraform** uses S3 remote state with native lockfile locking, so repeated runs reconcile
  the same resources instead of creating duplicates.
- **Ansible** uses `community.docker` modules and apt package state, so re-running converges the
  host rather than stacking changes. Pushing again = safe redeploy.

## Why SSM instead of SSH

- No SSH key to generate, store, or rotate in GitHub.
- The deploy path needs **no inbound port** — SSM works outbound-only via the instance's IAM role.
- Ports 22 and 80 are still opened in the security group (per request): 22 for manual break-glass
  SSH if you ever add a key, 80 to serve Mattermost.

## Local run (optional)

```bash
cd terraform
terraform init -backend-config="bucket=my-mattermost-tfstate"
terraform apply -var "ssm_transfer_bucket=my-mattermost-ssm-transfer"

cd ../ansible
ansible-galaxy collection install -r requirements.yml
export TARGET_INSTANCE_ID=$(cd ../terraform && terraform output -raw instance_id)
export SSM_BUCKET=my-mattermost-ssm-transfer
export AWS_REGION=ap-south-1
ansible-playbook playbook.yml \
  -e "mysql_root_password=... mysql_password=... site_url=http://$(cd ../terraform && terraform output -raw public_ip)"
```

## Teardown

```bash
cd terraform
terraform destroy -var "ssm_transfer_bucket=my-mattermost-ssm-transfer"
```

> `destroy` removes the EC2 host and its data. Empty the S3 buckets separately if you no longer
> need the state/transfer buckets.
