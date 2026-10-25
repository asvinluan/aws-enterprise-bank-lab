# Stop the meter: what is billing you, and how to switch it off

This lab creates a few services that charge by the hour whether or not anything is using them. This page lists them in the order they cost money, shows how to switch each one off, and gives you a script that does it safely.

Prices below are approximate, in USD, and were checked on 25 October 2026. Check the AWS pricing page for the exact figure before you rely on one.

## The short version

1. Open **CloudShell** in the AWS Console (the `>_` icon in the top bar), in the same account as the lab.
2. Upload `stop-the-meter.sh` (Actions menu, then Upload file) and run:

```bash
chmod +x stop-the-meter.sh
./stop-the-meter.sh scan                      # read-only: shows what exists
./stop-the-meter.sh costs                     # what you were charged per service, last 7 days
./stop-the-meter.sh delete all                # DRY RUN: prints what it would delete
./stop-the-meter.sh delete all --yes          # does it
./stop-the-meter.sh scan                      # confirm it is empty
```

The script only touches things named `MB-*`, `mb-*` or `meridian-lab*`, or inside the VPC tagged `mb-vpc`. Phone numbers, the Connect instance and KMS keys are skipped unless you add an extra flag (see "Things the script will not do unless you ask").

## What costs money, biggest first

| # | Service | Why it bills | Rough cost | How to stop it |
|---|---|---|---|---|
| 1 | **EKS cluster** | Control plane bills every hour. The lab pins Kubernetes 1.31, which left standard support on 26 Nov 2025, so it bills at the extended-support rate. | 0.60 USD/hour, about 14 USD/day, about 440 USD/month (standard support is 0.10 USD/hour) | `delete eks` |
| 2 | **EKS worker nodes** (2 x t3.small) and the internal load balancer the Kubernetes Service creates | EC2 hours, EBS volumes, load balancer hours | a few USD/day together | `delete eks` then `delete lb` |
| 3 | **Interface VPC endpoints** (8 of them, 3 AZs each = 24 network interfaces) | Hourly charge per endpoint per AZ, plus per GB | about 0.01 USD per endpoint-AZ-hour, so about 5 to 6 USD/day | `delete endpoints` |
| 4 | **NAT gateway** | Hourly charge plus per GB processed | 0.059 USD/hour in Sydney, about 1.40 USD/day, about 43 USD/month, plus data | `delete nat` |
| 5 | **Public IPv4 addresses** (the NAT's Elastic IP, any public IP on a node) | Every public IPv4 address bills hourly, attached or not | 0.005 USD/hour each, about 3.60 USD/month | `delete eip` |
| 6 | **Kinesis Data Streams** (MB-CTR, MB-AgentEvents) | Per shard-hour, even with no traffic | about 0.02 USD/shard-hour in many Regions | `delete streams` |
| 7 | **Amazon Connect claimed phone number** | Daily charge for each claimed number, plus usage | small per day but it never stops | `delete numbers --include-numbers` |
| 8 | **AWS WAF web ACL** | Monthly fee per web ACL, per rule and per million requests | about 5 USD/month per ACL plus 1 USD per rule | `delete waf` |
| 9 | **KMS customer-managed keys** | Per key per month | about 1 USD/month each | `delete kms --include-kms` |
| 10 | **Secrets Manager secret** | Per secret per month | about 0.40 USD/month each | delete in console (see below) |
| 11 | **CloudWatch** alarms, logs, Bedrock invocation logs | Per alarm per month, per GB ingested and stored | cents to a few USD | `delete alarms`, `delete logs` |
| 12 | **S3, ECR, DynamoDB, Firehose, Athena, Lambda, API Gateway** | Storage and requests | cents when idle | `delete s3 ecr dynamodb streams analytics lambda apigw` |

Free once idle: the VPC, subnets, route tables, internet gateway, security groups, gateway endpoints (S3 and DynamoDB), and IAM roles.

### Why EKS is item 1

The lab YAML says `version: "1.31"`. AWS gives each Kubernetes version 14 months of standard support, then 12 months of extended support. Version 1.31 was released on 26 September 2024, standard support ended on 26 November 2025, and extended support ends on 26 November 2026. A cluster created on 1.31 today is in extended support from the first hour. That is 6 times the normal control-plane price. If you ever rebuild the lab, use a version that is still in standard support (the Terraform in this repo defaults to 1.35, which is in standard support until 27 March 2027).

Sources: [endoflife.date/amazon-eks](https://endoflife.date/amazon-eks) for the dates, and the [AWS Containers Blog on extended-support pricing](https://aws.amazon.com/blogs/containers/amazon-eks-extended-support-for-kubernetes-versions-pricing/) for the 0.10 and 0.60 USD figures.

## Do these four things first (about 5 minutes)

If you only have time for four things, do these. They are the large ones.

1. **Delete the EKS cluster.** Console: EKS, then Clusters, then `meridian-lab`, then Delete the node group first, then the cluster. Or run `./stop-the-meter.sh delete eks --yes`. If you created it with `eksctl`: `eksctl delete cluster --name meridian-lab --region ap-southeast-2`.
2. **Delete the NAT gateway and release its Elastic IP.** Console: VPC, then NAT gateways, then Delete. Wait for the state to read `Deleted` (about a minute), then VPC, then Elastic IPs, then Release.
3. **Delete the interface endpoints.** Console: VPC, then Endpoints. Select every row whose type is `Interface` and choose Delete. Leave the two `Gateway` rows: they are free.
4. **Release the claimed phone number** if you no longer need it. Console: Amazon Connect, admin site, Channels, Phone numbers. Be aware that Australian and 1300 numbers need a support case to claim, so you may not get the same number back.

Then run the full script for the rest.

## Things the script will not do unless you ask

| Flag | What it unlocks | Why it is gated |
|---|---|---|
| `--include-numbers` | Releases every claimed Connect phone number in the Region | You cannot get the same number back. |
| `--include-instance` | Deletes a Connect instance whose alias starts with `meridian-cc` | An instance with a different alias, such as your earlier lab, is always skipped. |
| `--include-kms` | Schedules deletion (7 days, cancellable) of keys with an alias starting `alias/mb-` | Deleting a key makes everything encrypted with it unreadable. |
| `--include-untagged-eips` | Releases unattached Elastic IPs that have no Name tag | The NAT gateway's address is usually untagged, but so might be one you want to keep. |

### The KMS key your Q in Connect knowledge base uses

The earlier labs in the `amazon-connect-lab` repository created a KMS key with the alias `asvinluan-connect-lab-events`. The Q in Connect knowledge base is encrypted with it. The script refuses to schedule that key for deletion. If you destroy the event lab and delete that key, the knowledge base stops working. Your screenshots and the public repository already hold the evidence, so that is your decision to make deliberately, not by accident.

## Doing it by hand in the console

Use this if you would rather click than run a script. The order matters, because AWS refuses to delete something that another resource still depends on.

1. EKS: delete the node group, then the cluster. In EC2, Load Balancers: delete any load balancer in `mb-vpc`.
2. VPC, NAT gateways: delete. Wait. Then Elastic IPs: release.
3. VPC, Endpoints: delete every `Interface` endpoint.
4. WAF & Shield, Web ACLs (Region Sydney): open `MB-Web-ACL`, Associated AWS resources, Disassociate, then Delete the web ACL.
5. API Gateway: delete `MB-Web-API`.
6. Lambda: delete every `MB-*` function.
7. ECR: delete the repository `mb/account-service`.
8. Kinesis: delete `MB-CTR` and `MB-AgentEvents`. Firehose: delete the delivery stream. If Connect refuses because it still uses the stream, remove it first under the Connect instance, Data streaming.
9. VPC, Your VPCs, `mb-vpc`, Flow logs tab: delete the flow log.
10. CloudWatch: delete the `MB-*` alarms and the log groups for the lab.
11. S3: empty then delete each `mb-*` bucket. Turn on "Show versions" when you empty a versioned bucket.
12. DynamoDB: delete `MB-Customers`, `MB-Holidays`, `MB-Contacts`.
13. Amazon Connect: release the phone number, then the instance if you are finished with it.
14. KMS: Customer managed keys, Key actions, Schedule key deletion (minimum 7 days). Skip the `asvinluan-connect-lab-events` key unless you have decided to retire the Q in Connect knowledge base.
15. Secrets Manager: delete secrets you no longer need. Deleting `lab/salesforce` breaks the Salesforce lab, so rotate it instead if you are only worried about exposure.
16. VPC: once the endpoints, NAT gateway and network interfaces are gone, delete the subnets, route tables, internet gateway, security groups and finally the VPC.

### Services that sit outside the script

Check these in the console, because they use different APIs and the lab text says to create them in the UI:

* **Amazon Q in Connect / AI agents** (Connect console, your instance, Amazon Q or AI agents): remove the assistant association. The domain and knowledge base are billed by usage. I could not verify that the domain can be deleted from the CLI, so do it in the console.
* **Bedrock**: Settings, Model invocation logging. If it is on, turn it off. Delete the `mb-guardrail` guardrail (it has no standing charge, but tidy up).
* **Contact Lens and Voice ID**: usage-billed. Nothing to delete once calls stop. Delete the Voice ID domain if you created one.
* **CloudFront**: if you created a distribution for Module 9, disable it, wait for the status to say `Deployed`, then delete it.

## Confirm it worked

1. Run `./stop-the-meter.sh scan`. Sections 1 to 9 should be empty.
2. Billing and Cost Management, then Cost Explorer. Group by Service, daily. Cost data can lag by up to 24 hours, so check again tomorrow. The line for EKS, EC2-Other (which is where NAT and endpoint hours show up), VPC, and Kinesis should fall to zero.
3. Look at Billing, then Bills, for the current month. This is what you will actually be invoiced.

## Put a stop-loss in place

A budget alert would have caught this on day one.

Console: Billing and Cost Management, Budgets, Create budget, "Use a template (simplified)", **Monthly cost budget**, set 10 USD, enter your email. You get an email at 85 percent and 100 percent of the amount, and when the forecast says you will pass it.

Or from CloudShell:

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
aws budgets create-budget --account-id "$ACCOUNT" \
  --budget '{"BudgetName":"lab-guard-10usd","BudgetLimit":{"Amount":"10","Unit":"USD"},"TimeUnit":"MONTHLY","BudgetType":"COST"}' \
  --notifications-with-subscribers '[{"Notification":{"NotificationType":"ACTUAL","ComparisonOperator":"GREATER_THAN","Threshold":80,"ThresholdType":"PERCENTAGE"},"Subscribers":[{"SubscriptionType":"EMAIL","Address":"YOUR_EMAIL_HERE"}]}]'
```

Replace `YOUR_EMAIL_HERE`. Also turn on Billing preferences, "Receive CloudWatch billing alerts" and "Cost Anomaly Detection", which is free.

## Charges you have already incurred

Deleting resources stops new charges. It does not refund old ones. AWS Support will sometimes grant a one-off goodwill credit when a learner left something running by mistake, especially for a first request. Open a support case under "Account and billing", say what you built, say you have deleted it, and ask. It is a request, not a right.

## How to avoid this next time

* Build the expensive parts only when you are testing them. This repository's Terraform has a switch for each one (`enable_nat`, `enable_interface_endpoints`, `enable_eks`, `enable_firehose`) and they all default to off.
* Run `terraform destroy` the same day. It removes everything the code created, in the right order.
* Keep the 10 USD budget alarm on permanently.
