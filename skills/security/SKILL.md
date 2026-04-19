---
id: security
name: Security
description: Security assessment — reconnaissance, web application testing, vulnerability analysis, and threat intelligence.
triggers:
  - security
  - recon
  - reconnaissance
  - port scan
  - subdomain
  - DNS
  - WHOIS
  - pentest
  - vulnerability
  - threat model
  - web assessment
  - attack surface
  - bug bounty
tags:
  - security
  - assessment
  - recon
requires:
  delegation: false
  inference: true
---

# Security

Security assessment framework covering network reconnaissance, web application testing, and vulnerability analysis.

## Workflows

### Recon
Network reconnaissance — subdomain enumeration, port scanning, DNS/WHOIS/ASN lookups, endpoint discovery, path discovery, CIDR/netblock analysis. Passive and active modes.

### Web Assessment
Web application security testing — application understanding, threat modelling, OWASP testing methodology, fuzzing, and AI-assisted vulnerability analysis.

### Threat Model
Structured threat modelling for an application or system. Identifies assets, threat actors, attack vectors, and mitigations.

## Degradation

- **With delegation**: Parallel scanning across multiple targets, concurrent vulnerability analysis.
- **Without delegation**: Sequential execution. All capabilities remain available but run one at a time.

## Ethical Requirements

All security assessment activities require explicit authorization from the asset owner. Reconnaissance is limited to targets you have permission to test.
