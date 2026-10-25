# Playbook: the 19 modules in one page each

The original lab is about 60 pages. This is the short version. Each chapter has the same five parts:

* **Goal**: the problem the chapter solves.
* **Architecture**: what exists when it is finished.
* **Commands**: the commands or console steps that matter. Console-only work is described, not scripted.
* **Terraform**: where the same thing lives in this repository. "Console only" means the code deliberately does not create it.
* **Cleanup**: how to remove it, and whether it costs money while it exists.

Terraform lives in `terraform/`, CloudFormation in `cloudformation/`, application code in `app/`. Cleanup for everything: `cleanup/stop-the-meter.sh` (see `docs/CLEANUP.md`).

**Naming convention** (used throughout): Connect instance alias `meridian-cc`; prefix `MB-`; tables `MB-Customers`, `MB-Holidays`, `MB-Contacts`; Lambdas `MB-CallerLookup`, `MB-HolidayCheck`, `MB-StartChat`, `MB-SendSms`, `MB-RecordingRouter`; role `MB-LambdaRole`; Lex bot `MB-Bot`, alias `Prod`; queues `MB-Priority-Q`, `MB-General-Q`, `MB-Fraud-Q`, `MB-Overflow-Q`; streams `MB-CTR`, `MB-AgentEvents`; bucket `mb-recordings-<account-id>`.

**Cost key:** 🟢 free or cents when idle, 🟡 small standing charge, 🔴 bills by the hour: delete the same day.

---

## Module 1: Foundations: account, Region, IAM  🟢

**Goal.** Somewhere to put things, and a way to control who may do what. In a bank, access control is the first thing an auditor examines.

**Architecture.** One account in `ap-southeast-2` (Sydney). In the real world: an AWS Organization with Security, Infrastructure, Workloads and Sandbox OUs, Service Control Policies (SCPs) denying other Regions, and one role for the Lambdas, `MB-LambdaRole`, with least-privilege permissions.

**Commands.**

* Console: set the Region to Sydney and leave it there.
* IAM, Policies: create `MB-LambdaPolicy` (read `MB-Customers` and `MB-Holidays`, write `MB-Contacts`, write logs, route recordings in the recordings bucket).
* IAM, Roles: create `MB-LambdaRole` trusted by `lambda.amazonaws.com`, attach the policy plus `AWSLambdaBasicExecutionRole`.
* Add `AWSLambdaVPCAccessExecutionRole` later, in Module 10.

**Terraform.** `terraform/modules/security/main.tf` (role, policy, managed-policy attachments, KMS key and alias).

**Cleanup.** Roles and policies are free. Delete the role last. A KMS key is about 1 USD/month: `stop-the-meter.sh delete kms --include-kms`.

---

## Module 2: The Amazon Connect instance  🟡

**Goal.** Something that can take a phone call, hold it, decide what to do and hand it to a person, without building telephony yourself.

**Architecture.** One Connect instance, alias `meridian-cc`, store users in Connect, inbound and outbound telephony on, data storage defaults (recordings, transcripts, reports). A claimed phone number. A reminder: **identity management cannot be changed after creation**. Check service quotas early (concurrent calls, phone numbers, queues, flows are soft limits).

**Commands (console).**

1. Amazon Connect, Create instance, alias `meridian-cc`.
2. Tick Incoming calls and Outgoing calls.
3. Accept data storage defaults. Create an administrator.
4. Log in at `https://meridian-cc.my.connect.aws`.
5. Channels, Phone numbers, Claim a number (Australian numbers need a support case).

**Terraform.** Console only, deliberately. `terraform/connect.tf` wires things to an instance whose ID you pass in `connect_instance_id` with `wire_connect = true`.

**Cleanup.** Release the number first (billed daily), then delete the instance (type the alias to confirm). Script: `delete numbers --include-numbers`, `delete instance --include-instance`.

---

## Module 3: The data layer: DynamoDB  🟢

**Goal.** A very fast lookup of "who is calling?" at call time, without a database server.

**Architecture.** Three on-demand tables.

| Table | Partition key | Purpose |
|---|---|---|
| `MB-Customers` | `phoneNumber` | Name, tier, product line, account reference |
| `MB-Holidays` | `holidayDate` | Date-driven closures and greetings |
| `MB-Contacts` | `contactId` | Written during the call, read by the recording router; TTL |

**Commands.**

```bash
aws dynamodb create-table --table-name MB-Customers \
  --attribute-definitions AttributeName=phoneNumber,AttributeType=S \
  --key-schema AttributeName=phoneNumber,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
```

Seed a row with your own mobile number (`+61…`). Never commit a real number.

**Terraform.** `terraform/modules/data/dynamodb.tf`; seed items from `seed_customers` and `seed_holidays` in `variables.tf`. CloudFormation cannot seed items: `cloudformation/seed-dynamodb.sh`.

**Cleanup.** Free when idle. `delete dynamodb`.

---

## Module 4: Compute and integration: Lambda  🟢

**Goal.** Small pieces of code the contact flow calls mid-call.

**Architecture.** Python 3.12, 8-second timeout (Connect's limit), execution role `MB-LambdaRole`, one idempotency guard on anything that creates a record (keyed on `ContactId`, written with `attribute_not_exists`).

| Function | Job |
|---|---|
| `MB-CallerLookup` | Phone number to customer record; later runs in the VPC |
| `MB-HolidayCheck` | Greeting and closure; **fails open** |
| `MB-StartChat` | Credential broker for the web chat |
| `MB-RecordingRouter` | Sorts recordings into tiers after the call |
| `MB-SendSms` | Sends an SMS; never raises |

**Commands.**

```bash
# in the Connect console: instance, Flows, AWS Lambda, add the function
# or by CLI, so Connect may invoke it
aws lambda add-permission --function-name MB-CallerLookup \
  --statement-id connect-invoke --action lambda:InvokeFunction \
  --principal connect.amazonaws.com --source-arn <INSTANCE_ARN>
```

Test with a JSON event in the Lambda console before wiring it to a flow.

**Terraform.** `terraform/modules/compute/lambda.tf`, code in `app/lambdas/*/lambda_function.py`. `connect.tf` creates the invoke permission when wired.

**Cleanup.** Free when idle. `delete lambda`. VPC-attached functions leave a network interface that can take minutes to disappear, which delays deleting subnets.

---

## Module 5: The routing model: hours, queues, profiles, agents  🟢

**Goal.** Send the right call to the right agent in the right order.

**Architecture.** Hours (`MB-Hours-Business` with an IANA time zone, `MB-Hours-24x7` for fraud) → queues (`MB-Priority-Q`, `MB-General-Q`, `MB-Fraud-Q`, `MB-Overflow-Q`, each with a **maximum contacts** value) → routing profiles (`MB-RP-Priority`, `MB-RP-General`, `MB-RP-Universal`, `MB-RP-Fraud`) → agents. Priority overrides wait time; delay holds a queue back from an agent for N seconds. The trap: heavy priority volume starves the general queue.

**Commands (admin website, with one CLI example).**

```bash
aws connect update-user-routing-profile --instance-id <ID> \
  --user-id <USER_ID> --routing-profile-id <PROFILE_ID>
```

Attach quick connects to the agent's queue or they will not appear in the transfer list.

**Terraform.** Console only.

**Cleanup.** Free. Delete in this order: flows, quick connects, routing profiles, queues, hours.

---

## Module 6: Contact flows, fully wired  🟢

**Goal.** The call journey: greet, identify, branch, queue.

**Architecture.** `MB-IdentifyCaller` (a reusable module), `MB-Main`, `MB-CustomerQueue`, `MB-BreakGlass`. Rules: **every branch lands somewhere**; **Transfer to queue, Success must be connected**; `$.External` holds only the latest Lambda result, so copy values into attributes at once; only disconnect after a spoken message; retry loops capped at two, then a human.

When a queue is full: overflow, callback, bounded self-service, voicemail, apology. Never a silent disconnect.

**Commands.** Admin website, Routing, Flows. After every edit: **Save, then Publish**. Note the flow ID (last part of its ARN); Module 9 needs it.

**Terraform.** Console only. Export published flows to JSON and commit them if you want version control.

**Cleanup.** Delete flows and the module in the admin site.

---

## Module 7: Conversational AI: Amazon Lex V2  🟢

**Goal.** Let callers say what they want instead of pressing keys.

**Architecture.** `MB-Bot` with intents (balance, lost card, speak to someone, fallback), restricted slot types, confidence threshold **0.55**, slot obfuscation on, confirmation on money-moving intents, DTMF enabled on every input, a numbered **version** and a `Prod` **alias** that the flow points at.

**Commands (Lex console).** Build, create a version, create or repoint alias `Prod`, add the alias to the Connect instance (Flows, Amazon Lex). Test with the built-in tester, then by phone.

**Terraform.** Console only.

**Cleanup.** Delete alias `Prod`, then the version, then the bot. Free when idle.

---

## Module 8: Contact Lens, Amazon Q, Bedrock and agentic AI  🟡

**Goal.** Analyse, assist and automate, scoped by the cost of being wrong.

**Architecture.** Contact Lens (sentiment, categories, **redaction on from day one**); Amazon Q in Connect (agent assist from a knowledge base); a Bedrock **guardrail** (denied topic: personal financial advice; created first, versioned, referenced by version); Voice ID (explicit consent, opt-out, one factor only); agentic AI as the highest-risk tier, with a tool boundary.

**Commands (console).** Connect instance, Analytics tools (Contact Lens); Amazon Q (create domain, add knowledge base); Bedrock, Guardrails, create `mb-guardrail`, create version.

**Terraform.** Console only. These services have usage-based billing and the lab keeps them out of code.

**Cleanup.** Remove the Q assistant association; delete the knowledge base and domain in the console; turn off Bedrock model-invocation logging; delete the guardrail. Check these by hand: they sit outside the script. **Do not delete the KMS key your Q knowledge base uses.**

---

## Module 9: The web layer: CloudFront, WAF, API Gateway  🟡

**Goal.** Let a website start a chat without putting AWS credentials in a browser, and protect that door.

**Architecture.** Browser → CloudFront → WAF → API Gateway (`POST /chat`) → `MB-StartChat` → Connect `StartChatContact` → participant token → browser talks to Connect directly. WAF rules: rate-based **100 per 5 minutes per IP**, AWS managed Common and Known Bad Inputs, geo-match (not Australia) in **count** mode. WAF governs contact **initiation**, not content.

**Commands.**

```bash
curl -X POST https://<API_ID>.execute-api.ap-southeast-2.amazonaws.com/prod/chat \
  -H 'Content-Type: application/json' -d '{"name":"Test"}'

# flood test: expect 403s after the limit
for i in $(seq 1 150); do
  curl -s -o /dev/null -w "%{http_code} " -X POST <URL> -d '{"name":"x"}'
done
```

**Terraform.** `terraform/modules/compute/api.tf` and `waf.tf` (`enable_waf`, default off). CloudFormation: `cloudformation/03-compute-edge.yaml`.

**Cleanup.** Disassociate the web ACL, then delete it. Delete the API. Disable, wait for `Deployed`, delete the CloudFront distribution. 🔴 The WAF costs about 5 USD/month plus 1 USD per rule.

---

## Module 10: Networking: build the VPC  🔴

**Goal.** A real network for the Lambda and the cluster to live in, designed rather than inherited.

**Architecture.** VPC `10.20.0.0/16`, DNS support and hostnames on; three tiers across three AZs (public `/24`, private `/23`, isolated `/24`); one internet gateway; one NAT gateway in public-a (cost-saving compromise; one per AZ in production); route tables (public → IGW, private → NAT, isolated → nothing); security groups by reference (`sg-lambda` → `sg-account-service` on 8080); free **gateway endpoints** for S3 and DynamoDB; **interface endpoints** for `kms`, `secretsmanager`, `kinesis-streams`, `bedrock-runtime`, `ecr.api`, `ecr.dkr`, `logs`, `sts`, with an endpoint policy as an exfiltration control; VPC Flow Logs.

**Commands.**

```bash
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames
aws ec2 attach-internet-gateway --vpc-id $VPC_ID --internet-gateway-id $IGW_ID
aws ec2 wait nat-gateway-available --nat-gateway-ids $NAT_ID
aws ec2 create-route --route-table-id $RT_PRIV --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NAT_ID
aws ec2 create-vpc-endpoint --vpc-id $VPC_ID --service-name com.amazonaws.ap-southeast-2.s3 \
  --vpc-endpoint-type Gateway --route-table-ids $RT_PRIV
aws ec2 create-flow-logs --resource-type VPC --resource-ids $VPC_ID --traffic-type ALL \
  --log-group-name /aws/vpc/mb-flowlogs ...
```

Then attach `MB-CallerLookup` to the three private subnets and `sg-lambda` and re-test.

**Terraform.** `terraform/modules/network/main.tf`. Switches: `enable_nat`, `enable_interface_endpoints` (both default **off**), `enable_flow_logs` (default on). CloudFormation: `cloudformation/01-network.yaml`.

**Cleanup.** Order matters: delete NAT, wait, release the Elastic IP, delete interface endpoints, wait for network interfaces to disappear, then subnets, route tables, IGW, security groups, VPC. 🔴 NAT about 1.40 USD/day; the eight endpoints in three AZs about 5 to 6 USD/day. `delete nat`, `delete eip`, `delete endpoints`, `delete vpc`.

---

## Module 11: Containers: ECR and EKS, in your VPC  🔴

**Goal.** A realistic backend for the Lambda to call: the bank's account service on Kubernetes.

**Architecture.** A Flask service (`app/account-service`) packaged as an image in **ECR** (immutable tags, scan on push), run as three replicas on **EKS** inside the Module 10 private subnets with private networking, spread across zones, behind an **internal** load balancer. The Service listens on **8080**; the security group allows 8080 only from `sg-lambda`. Pin a Kubernetes version that is still in standard support.

**Commands.**

```bash
aws ecr create-repository --repository-name mb/account-service \
  --image-tag-mutability IMMUTABLE --image-scanning-configuration scanOnPush=true
aws ecr get-login-password | docker login --username AWS --password-stdin $ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com
docker build -t mb/account-service:v1 app/account-service
docker tag mb/account-service:v1 $ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/mb/account-service:v1
docker push $ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/mb/account-service:v1

eksctl create cluster -f cluster.yaml
kubectl apply -f app/k8s/deployment.yaml
kubectl get pods -o wide        # confirm the pods are spread across nodes
kubectl get svc account-service # the address should be private
```

**Terraform.** `terraform/modules/containers/ecr.tf` and `eks.tf` (`enable_eks`, default **off**, requires `enable_nat`). Manifest: `app/k8s/deployment.yaml`. CloudFormation: `cloudformation/04-containers.yaml`.

**Cleanup.** 🔴 The most expensive item. Delete the Service first so the load balancer goes, then the cluster. A lab pinned to Kubernetes 1.31 bills the extended-support rate, 0.60 USD/hour. `delete eks`, `delete lb`, `delete ecr`; or `eksctl delete cluster --name meridian-lab --region ap-southeast-2`.

---

## Module 12: Data plane and records: Kinesis, S3, retention  🔴 (Kinesis) / 🟢 (S3)

**Goal.** Reporting for the business, and recordings the regulator can trust for seven years.

**Architecture.** CTR and agent-event streams (`MB-CTR`, `MB-AgentEvents`) → Firehose (JSON to Parquet, buffer 64 MB or 5 minutes) → S3 data lake → Glue catalog → Athena. Recordings land in one S3 location; `MB-RecordingRouter` copies each into `recordings/priority/` or `recordings/general/` by tier. Lifecycle: Priority to Glacier Instant Retrieval, General to Glacier Flexible Retrieval. Evidence copy in a separate account with Object Lock (Compliance mode). Watch the 128 KB minimum-object-size trap.

**Commands.**

```bash
aws s3api put-bucket-lifecycle-configuration --bucket mb-recordings-$ACCOUNT_ID \
  --lifecycle-configuration file://lifecycle.json
# lifecycle.json must set transition_default_minimum_object_size = varies_by_storage_class
```

Connect console, instance, Data streaming: enable CTR and agent events to the streams. Add the S3 `ObjectCreated` trigger to `MB-RecordingRouter`, filtered to prefix `connect/`.

**Terraform.** `terraform/modules/data/s3.tf` and `streaming.tf` (`enable_kinesis`, `enable_firehose`, `enable_evidence_bucket`, all off). The S3 trigger is attached in `main.tf`. CloudFormation: `cloudformation/02-data.yaml` (the trigger is attached by `deploy.sh`).

**Cleanup.** 🔴 Kinesis bills per shard-hour even idle: `delete streams`. Empty versioned buckets with versions included: `delete s3`. Object Lock in Compliance mode cannot be emptied; that is the point.

---

## Module 13: Outbound: End User Messaging and campaigns  🟢

**Goal.** Let the bank contact the customer first.

**Architecture.** AWS End User Messaging for SMS (with a **configuration set** and event destination so delivery is observable); Connect outbound campaigns decide who, when and by which channel. Use TRANSACTIONAL for a fraud alert. Amazon Pinpoint ends support on **30 October 2026**. Australian sender IDs need registration, which takes time.

**Commands (console).** End User Messaging SMS, register an originator, create a configuration set. `MB-SendSms` calls the API and never raises.

**Terraform.** Function only (`app/lambdas/send_sms`). The originator is a console step.

**Cleanup.** Release the SMS originator (some bill monthly).

---

## Module 14: Observability: CloudWatch  🟡

**Goal.** Know it is broken before the customer does, and find out why fast.

**Architecture.** Contact flow logs, Lambda logs, VPC flow logs, CloudTrail. Alarms: `ContactFlowErrors`, `ContactFlowFatalErrors`, `MissedCalls`, `CallRecordingUploadError`, `ConcurrentCallsPercentage`, `LongestQueueWaitTime`; for Lambda `Errors`, `Throttles`, p99 `Duration` (alarm near 5 s), `ConcurrentExecutions`. Alarms go to an SNS topic someone actually reads.

**Troubleshooting order.** Published? → which branch? → did the Lambda run? → what did it return? → was the attribute set? → only then change code.

**Commands.** CloudWatch Logs Insights, filtered by `ContactId`; alarms in the console or Terraform.

**Terraform.** `terraform/modules/observability/main.tf` (`enable_alarms`, default off).

**Cleanup.** Alarms cost about 0.10 USD/month each; log groups cost by volume. `delete alarms`, `delete logs`.

---

## Module 15: Infrastructure as code: Terraform  🟢

**Goal.** Make the estate reviewable, repeatable and rebuildable.

**Architecture.** Modules by layer; remote state in S3 with locking, encrypted and versioned; provider pinned; one directory per environment; quality gates (`fmt`, `validate`, `tflint`, a security scanner, Infracost). Connect itself stays in the console; the code wires the parts Terraform owns.

**Commands.**

```bash
cd terraform
terraform init
terraform plan  -var-file=envs/minimal.tfvars
terraform apply -var-file=envs/minimal.tfvars
terraform output cost_switches
```

`envs/minimal.tfvars` builds only what is free when idle. `envs/full.tfvars` turns every paid switch on: use for a few hours only.

**Terraform.** The whole `terraform/` directory. Alternative: the four CloudFormation stacks under `cloudformation/` (`./deploy.sh`, `./destroy.sh`).

**Cleanup.** `terraform destroy -var-file=envs/full.tfvars` the same day. S3 buckets with objects need emptying first (or `force_destroy`).

---

## Module 16: The pipeline: GitHub Actions  🟢

**Goal.** Production changes only through a reviewed path.

**Architecture.** Pull request: `fmt -check`, `validate`, `tflint`, scanner, `plan` posted to the PR. Merge to `main`: `apply`. Credentials by **OIDC**: GitHub assumes a role with short-lived credentials; the trust policy's `sub` is pinned to one repository and branch. Nightly `terraform plan -detailed-exitcode` for drift.

**Commands.** `.github/workflows/ci.yml` in this repository runs the checks with **no** AWS credentials. To deploy, add an OIDC role and a second workflow.

**Terraform.** Role and trust policy are not included; add them to a bootstrap stack.

**Cleanup.** Delete the OIDC provider and role. Never store access keys in GitHub secrets.

---

## Module 17: Resiliency and disaster recovery  🟢

**Goal.** Know what fails, what recovers by itself, and what is a board-level risk.

**Architecture.** Connect is multi-AZ inside AWS and invisible to you. You own your supporting resources: three AZs for Lambda subnets, EKS spread, DynamoDB. **Global Resiliency is not available in Australia**, so the defence is single-Region Sydney with the Region-level risk accepted explicitly, a pre-published break-glass flow, carrier redirection, and configuration in Git. APRA CPS 230 requires board-approved tolerance levels; measure RTO and RPO with a timed drill.

**Commands.** Repoint the phone number to `MB-BreakGlass` and time it; scale the deployment to zero and confirm graceful degradation.

**Terraform.** Everything you can rebuild from code is the resilience story.

**Cleanup.** Nothing to delete.

---

## Module 18: Test the whole thing  🟢

**Goal.** Prove it works, then break it on purpose.

**Architecture.** 16 tests. The two most valuable: **T3** (scale the account service to zero: the caller is apologised to and routed to an agent, not dropped) and **T8** (revoke the Lambda's DynamoDB permission: degraded greeting, still routed). Anyone can demo the happy path.

**Commands.**

```bash
kubectl scale deployment account-service --replicas=0   # T3
curl -X POST https://<API>/prod/chat ...                # T14
```

Audit before testing: every Error branch connected; every Transfer to queue Success connected; every At capacity branch has a destination; every flow Published.

**Terraform.** Not applicable.

**Cleanup.** Restore the scale and permissions you changed.

---

## Module 19: Teardown  🔴

**Goal.** Stop paying. Same day.

**Architecture.** Reverse dependency order. A claimed number bills daily; an EKS cluster bills hourly.

**Commands.**

```bash
# CloudShell, in the lab account
./stop-the-meter.sh scan
./stop-the-meter.sh delete all            # dry run
./stop-the-meter.sh delete all --yes
./stop-the-meter.sh scan                  # confirm empty
```

Order: EKS and load balancer → NAT and Elastic IP → interface endpoints → phone number → WAF → API Gateway → Lambdas → ECR → Lex → Kinesis and Firehose → Connect flows, queues, profiles → DynamoDB → IAM → alarms and logs → Connect instance → S3 → KMS → SMS originator.

**Terraform.** `terraform destroy` removes what Terraform created, in the right order.

**Cleanup.** Then set a 10 USD AWS Budget so this cannot happen quietly again.

---

## The one-page cheat sheet

| If someone asks… | Say… |
|---|---|
| Why is Connect not in your VPC? | It is fully managed. It invokes a Lambda; the Lambda lives in the VPC. |
| What makes a subnet private? | Its route table, not a checkbox: `0.0.0.0/0` goes to a NAT gateway, not an internet gateway. |
| Why endpoints? | Security (endpoint policy as an exfiltration control) and cost (no NAT data charge). Gateway endpoints are free. |
| What does WAF protect? | Contact initiation, not content. |
| What is the worst Connect bug? | An unconnected branch: the caller is silently dropped. |
| Why DynamoDB? | One key, one read, no connection pool. Bad at ad-hoc queries: those go to Athena. |
| Priority versus wait time? | Priority wins, so watch for starvation. |
| What is your DR story in Australia? | Global Resiliency is not available here. Single Region, accepted at board level, tested break-glass, everything rebuildable from code. |
| What cost you money? | EKS control plane, NAT, interface endpoints, Kinesis shards, claimed numbers. I built switches so they default to off. |
