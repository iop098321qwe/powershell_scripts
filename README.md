# Powershell Scripts
* This is a repository of powershell scripts to perform specific tasks.
* PowerShell style

## Scripts

### `audit_inactive_ad_users.ps1`

Audit enabled Active Directory users whose most recent logon is older than N
days. The script discovers all domain controllers in the domain, reads each
user's non-replicated `lastLogon` attribute from each DC, and keeps the most
recent value per user.

Objects are always written to the pipeline. Use `-OutputPath` to also export a
CSV.

Examples:

```powershell
./audit_inactive_ad_users.ps1 -DaysInactive 30 -OutputPath .\inactive_users.csv

./audit_inactive_ad_users.ps1 -SearchBase "OU=Users,DC=example,DC=com" |
  Sort-Object DaysSinceLastLogon -Descending
```
