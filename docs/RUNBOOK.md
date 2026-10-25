# Runbook: get it running, then get it deleted

For a tired engineer. Copy and paste. Each step says what you should see. If you only read one page of this repository, read this one.

**What this builds:** the Meridian Bank platform in Sydney (`ap-southeast-2`): network, Lambdas, API, data stores, and optionally the expensive parts (NAT, endpoints, EKS, Kinesis, WAF).
**What it does not build:** the Amazon Connect instance, flows, queues, Lex bot, Contact Lens and Q. Those are console work (see Part 5).

---

## Part 0. Five checks before anything (3 minutes)

| # | Check | How |
|---|---|---|
| 1 | You are in a **sandbox** account, not a work account | Look at the account alias in the console |
| 2 | The Region is **Asia Pacific (Sydney)** | Top-right of the console |
| 3 | A **budget alarm** exists | Billing, Budgets, create a 10 USD monthly budget (steps in `CLEANUP.md`) |
| 4 | Nothing from an earlier run is still billing | CloudShell: `./cleanup/stop-the-meter.sh scan` should be empty |
| 5 | You have decided **today's end time** | The expensive profile costs about 25 to 30 USD a day. Plan to destroy it the same day |

Where to run commands: **AWS CloudShell** (the `>_` icon in the console top bar). It already has the AWS CLI, git, Docker and credentials. You need to install Terraform in it once (Part 2, step 1).

---

## Pick one track

| Track | Use it when | Time |
|---|---|---|
| **A. GitHub** | You want the repo online with a green tick (do this once) | 10 min |
| **B. Terraform** | You want the estate built from code (recommended) | cheap profile 10 min, full profile 40 min |
| **C. CloudFormation** | You want AWS-native stacks, or you are not allowed Terraform | cheap profile 15 min, full profile 45 min |

Use **B or C, not both**, in the same account at the same time: they would try to create the same names.

---

## Part 1. Track A: GitHub

Run on **your PC**, not in CloudShell.

```bash
unzip aws-enterprise-bank-lab.zip
cd aws-enterprise-bank-lab
git init -b main
git add -A

# Safety check. Both commands must print NOTHING.
git grep --cached -nE '(^|[^0-9])[0-9]{12}([^0-9]|$)' | grep -vE 'ACCOUNT|123456789012|\.github/workflows|0{12}'
git grep --cached -nE 'AKIA[0-9A-Z]{16}|aws_secret_access_key|BEGIN .*PRIVATE KEY|ghp_|xox[bp]-' -- . ':!docs' ':!.github'

git commit -m "Initial commit: AWS enterprise bank lab"
gh repo create asvinluan/aws-enterprise-bank-lab --public --source=. --remote=origin --push
```

No `gh`? Create an empty repo in the browser, then:

```bash
git remote add origin https://github.com/asvinluan/aws-enterprise-bank-lab.git
git push -u origin main
```

**You should see:** the repo on GitHub, and under the **Actions** tab a `ci` run starting.

**What CI checks** (no AWS credentials involved): Terraform format, init, validate, TFLint; Trivy scan; cfn-lint; ShellCheck; Python compile; a scan for committed account IDs and keys.

**If CI is red** on the first run, that is normal: it is the first time the Terraform meets a real `terraform validate`. Open the failed step, read the one-line error, fix the file, push again. Do not skip it.

**One more step after it goes green:** run `terraform init` once on your PC inside `terraform/`, then commit `terraform/.terraform.lock.hcl`. That pins the provider versions.

Never put AWS access keys in GitHub. If you later deploy from GitHub, use OIDC (see `REPO-PUSH.md`).

---

## Part 2. Track B: Terraform

### Step 1. Get Terraform into CloudShell (once)

```bash
mkdir -p ~/bin && cd ~/bin
curl -sLO https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_linux_amd64.zip
unzip -o terraform_1.9.8_linux_amd64.zip && rm terraform_1.9.8_linux_amd64.zip
export PATH=$HOME/bin:$PATH
terraform version
```

**You should see:** `Terraform v1.9.8`. (CloudShell keeps `~/bin` between sessions but not your PATH, so repeat the `export` line in each new session.)

### Step 2. Get the code into CloudShell

CloudShell, Actions menu, Upload file, choose `aws-enterprise-bank-lab.zip`.

```bash
unzip -o aws-enterprise-bank-lab.zip
cd aws-enterprise-bank-lab/terraform
```

Or `git clone https://github.com/asvinluan/aws-enterprise-bank-lab.git` if you pushed it.

### Step 3. The cheap profile (cents a day)

```bash
terraform init
terraform plan  -var-file=envs/minimal.tfvars     # read it before you apply
terraform apply -var-file=envs/minimal.tfvars     # type yes
terraform output cost_switches
```

**You should see:** `Apply complete!` and `cost_switches` showing every paid switch as `false`.

Check the three zone IDs are different:

```bash
terraform output private_subnet_zone_ids          # three different apse2-azN values
```

### Step 4. Put your own phone number in (optional, never commit it)

Create `terraform.tfvars` (git ignores it) with your number in the `seed_customers` map, copying the shape from `variables.tf`, then `terraform apply -var-file=envs/minimal.tfvars` again.

### Step 5. Test the chat endpoint (needs Connect wired, see Part 5)

```bash
curl -s -X POST "$(terraform output -raw chat_url)" -H 'Content-Type: application/json' -d '{"name":"Test"}'
```

### Step 6. The expensive profile (only if you need to demo it)

Everything on costs about 25 to 30 USD a day. Do it in one sitting.

1. Edit `envs/full.tfvars`. **Uncomment and set** `eks_public_access_cidrs = ["YOUR.IP.ADDRESS/32"]`. Find your IP with `curl -s https://checkip.amazonaws.com`.
2. Apply:

```bash
terraform apply -var-file=envs/full.tfvars        # about 15 to 20 minutes, the cluster is the slow part
terraform output cost_switches                    # now shows what is billing
```

3. Build and push the container image:

```bash
cd ../app/account-service
REPO=$(cd ../../terraform && terraform output -raw ecr_repository_url)
aws ecr get-login-password --region ap-southeast-2 | docker login --username AWS --password-stdin "${REPO%%/*}"
docker build -t "$REPO:v1" .
docker push "$REPO:v1"
```

4. Point `kubectl` at the cluster and deploy:

```bash
cd ../../terraform
aws eks update-kubeconfig --region ap-southeast-2 --name "$(terraform output -raw eks_cluster_name)"
cd ../app/k8s
SG=$(cd ../../terraform && terraform output -raw sg_account_service_id)
ACCT=$(aws sts get-caller-identity --query Account --output text)
sed -e "s/SG_ACCOUNT_SERVICE_ID/$SG/" -e "s/ACCOUNT_ID/$ACCT/" deployment.yaml | kubectl apply -f -
kubectl get pods -o wide                          # 3 pods Running, spread over nodes
kubectl get svc account-service                   # EXTERNAL-IP is a private (internal) DNS name
```

5. Hand the service address to the Lambda. Take the DNS name from the last command and re-apply:

```bash
cd ../../terraform
terraform apply -var-file=envs/full.tfvars -var 'account_api_url=http://INTERNAL-DNS-NAME:8080'
```

**You should see:** three `Running` pods and an internal address that starts with `internal-`. If the address does not start with `internal-`, stop and delete the Service: it is exposed to the internet.

### Step 7. Destroy (same day)

```bash
cd ~/aws-enterprise-bank-lab/app/k8s && kubectl delete -f deployment.yaml   # removes the load balancer first
cd ../../terraform
terraform destroy -var-file=envs/full.tfvars     # use the same file you applied with
../cleanup/stop-the-meter.sh scan                # must be empty
```

Buckets are created with `force_destroy_buckets = true` (the default), so `destroy` empties them. The one exception is the optional Object Lock evidence bucket: it keeps objects for one day (Governance mode), so if `destroy` stops there, run `../cleanup/stop-the-meter.sh delete s3 --yes`, which bypasses governance retention.

---

## Part 3. Track C: CloudFormation

The four stacks are independent deployments linked by exports. Order matters once on the way up.

### Step 1. Get the code into CloudShell

Upload the zip and unzip it as in Part 2, step 2, then:

```bash
cd aws-enterprise-bank-lab/cloudformation
chmod +x *.sh
```

### Step 2. The cheap profile (cents a day)

```bash
./deploy.sh data
./deploy.sh network
./deploy.sh compute
./deploy.sh containers
./seed-dynamodb.sh
```

Each command prints a table of outputs at the end. **You should see** `CREATE_COMPLETE` or `UPDATE_COMPLETE` for each stack. `containers` creates only the ECR repository while EKS is off. `seed-dynamodb.sh` loads the demo customers and holidays (CloudFormation cannot). Open it first and replace the first phone number with your own mobile in `+61…` form, on your PC copy only, never in a commit.

`compute` also attaches the S3 trigger to the recordings bucket, filtered to the `connect/` prefix. That is required: without the prefix the router would fire on its own output forever.

### Step 3. The expensive profile (only if you need it)

```bash
MY_IP=$(curl -s https://checkip.amazonaws.com)

./deploy.sh data    EnableKinesis=true EnableFirehose=true EnableEvidenceBucket=true
./deploy.sh network EnableNat=true EnableInterfaceEndpoints=true
./deploy.sh compute EnableWaf=true EnableAlarms=true AlarmEmail=you@example.com
./deploy.sh containers EnableEks=true ApiAccessCidr=${MY_IP}/32     # 15 to 20 minutes
```

**Important:** `containers` defaults `ApiAccessCidr` to `0.0.0.0/0`. Always set it to your own `/32`.

Then build the image and deploy to the cluster exactly as Part 2, step 6, items 3 and 4, with these differences: the repository URI is the stack output `RepositoryUri`, the cluster name is `meridian-lab`, and the security group ID is the `SgAccountServiceId` output from the network stack:

```bash
aws cloudformation describe-stacks --stack-name mb-containers --query 'Stacks[0].Outputs' --output table
aws cloudformation describe-stacks --stack-name mb-network    --query 'Stacks[0].Outputs' --output table
```

Finally give the Lambda the service address and redeploy compute:

```bash
./deploy.sh compute AccountApiUrl=http://INTERNAL-DNS-NAME:8080 EnableWaf=true EnableAlarms=true AlarmEmail=you@example.com
```

(Repeat every non-default parameter on each `deploy.sh compute` call, or it reverts to the cheap default.)

### Step 4. Destroy (same day)

```bash
kubectl delete -f ../app/k8s/deployment.yaml     # if you deployed it: removes the load balancer first
./destroy.sh                                      # DRY RUN: read what it lists
./destroy.sh --yes                                # containers, compute, data, network, in that order
../cleanup/stop-the-meter.sh scan                 # must be empty
```

`destroy.sh` empties the buckets first, because CloudFormation cannot delete a bucket that has objects.

---

## Part 4. The one-command safety net

Whatever track you used, this finds and removes anything billing, and is safe to run twice:

```bash
./cleanup/stop-the-meter.sh scan                  # what exists
./cleanup/stop-the-meter.sh costs                 # what you were charged, last 7 days
./cleanup/stop-the-meter.sh delete all            # DRY RUN
./cleanup/stop-the-meter.sh delete all --yes      # real
```

It leaves Connect phone numbers, the Connect instance and KMS keys alone unless you add `--include-numbers`, `--include-instance` or `--include-kms`.

---

## Part 5. What the code does not do: the Connect console work

Do these in order. Full detail is in `PLAYBOOK.md` (modules 2, 5, 6, 7, 8).

1. **Create the instance** (alias `meridian-cc`, store users in Connect). Claim a number if you need a phone. Note the **instance ID** (the UUID in the instance ARN).
2. **Build** hours of operation, queues (set a maximum contacts value on each), routing profiles, quick connects.
3. **Build the flows**: `MB-IdentifyCaller` module, `MB-Main`, `MB-CustomerQueue`, `MB-BreakGlass`. Save, then **Publish** each. Note the `MB-Main` flow ID.
4. **Build the Lex bot** `MB-Bot`, version it, create alias `Prod`, add it to the instance.
5. **Wire the code to the instance.** Terraform: put these in `terraform.tfvars` and apply again:

```hcl
connect_instance_id      = "<instance uuid>"
connect_contact_flow_id  = "<MB-Main flow id>"
wire_connect             = true
```

CloudFormation: `./deploy.sh compute ConnectInstanceId=<uuid> ConnectContactFlowId=<flow id> WireConnect=true`.

6. **Call it.** Use the PLAYBOOK module 18 test table, especially T3 (scale the account service to zero) and T8 (remove the Lambda's DynamoDB permission).

---

## When it goes wrong

| What you see | Most likely cause | Fix |
|---|---|---|
| `terraform: command not found` | New CloudShell session | `export PATH=$HOME/bin:$PATH` |
| `enable_eks needs enable_nat` | Guard working as designed | Set `enable_nat = true` |
| `AccessDenied` on anything | Your role is too narrow | Use an admin role in a sandbox account |
| `Error acquiring the state lock` | An earlier run was cut off | `terraform force-unlock <ID>` (only if sure nobody else is running) |
| `BucketAlreadyExists` | Bucket names include your account ID, so this means a leftover | Run the clean-up script, or delete the old bucket |
| Lambda cannot reach DynamoDB from the VPC | Missing gateway endpoint or egress prefix list | `terraform plan` should show no drift; re-apply |
| Image pull fails on the nodes | S3 endpoint policy blocks the ECR layer bucket | Already allowed in this repo; check you did not edit the endpoint policy |
| Pods `Pending` | Not enough node capacity | `kubectl describe pod`, raise `eks_node_desired` |
| Service address is not `internal-…` | Annotation missing | `kubectl delete -f deployment.yaml` immediately, fix, redeploy |
| CloudFormation stack stuck `DELETE_FAILED` | A bucket has objects, or a network interface still exists | Run `destroy.sh --yes` again after a few minutes |
| Subnet will not delete | Leftover Lambda network interface (can last minutes) | Wait 10 to 20 minutes and retry |
| `Export ... cannot be deleted as it is in use` | You deleted in the wrong order | Delete `containers`, then `compute`, then `data` and `network` |
| Call drops with no message | A flow branch is not connected | `PLAYBOOK.md` module 6 checklist; check flow logs by `ContactId` |
| Bill is climbing | Something is still on | `stop-the-meter.sh scan`, then `delete all --yes` |

---

## Done checklist

- [ ] Budget alarm exists
- [ ] Cheap profile applied and `cost_switches` all `false` (or you know why not)
- [ ] If you turned on the full profile: the destroy command is written in your calendar for today
- [ ] `stop-the-meter.sh scan` is empty at the end of the day
- [ ] Repo is on GitHub, CI is green, no account IDs, keys or real phone numbers committed
