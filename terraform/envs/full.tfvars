# EVERYTHING ON. Use for a few hours to test, then run: terraform destroy
# Expect roughly 25 to 30 USD per day while it is up. See docs/CLEANUP.md.
enable_nat                 = true
enable_interface_endpoints = true
enable_eks                 = true
enable_kinesis             = true
enable_firehose            = true
enable_waf                 = true
enable_alarms              = true
enable_flow_logs           = true
enable_evidence_bucket     = true

# Restrict the Kubernetes API to your own address before applying:
# eks_public_access_cidrs = ["203.0.113.10/32"]

# After your Connect instance exists:
# connect_instance_id = "00000000-0000-0000-0000-000000000000"
# wire_connect        = true
# alarm_email         = "you@example.com"
