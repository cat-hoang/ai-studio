---
name: send-email-notification
description: Sends email notifications via SMTP using HTML templates. Supports task summaries, daily reports, and failure alerts.
parameters:
  templateName:
    type: string
    required: true
    enum: ["task-summary", "daily-report", "failed-alert"]
    description: The email template to use.
  data:
    type: object
    required: true
    description: >
      Template-specific data. Fields vary by template:
      - task-summary: jobNumber, taskType, description, status, prUrls (array), duration, zone
      - daily-report: date, workers (array of {name, zone, status, jobNumber, completedCount, failedCount}), totalCompleted, totalFailed, totalQueued
      - failed-alert: jobNumber, taskType, error, logs, zone, worker, timestamp
---

# Send Email Notification

Sends formatted HTML email notifications via SMTP for task lifecycle events and reporting.

## Steps

### 1. Read SMTP settings from config

```powershell
$ratatoskRoot = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $ratatoskRoot "config.local.yaml"
$configContent = Get-Content $configPath -Raw

function Get-YamlValue($content, $key) {
    if ($content -match "$key`:\s*(.+)") {
        return $Matches[1].Trim().Trim('"').Trim("'")
    }
    throw "$key not found in config.local.yaml"
}

$smtpServer = Get-YamlValue $configContent "smtp_server"
$smtpFrom   = Get-YamlValue $configContent "smtp_from"
$smtpTo     = Get-YamlValue $configContent "smtp_to"
```

Required config keys in `config.local.yaml`:
- `smtp_server`: SMTP relay hostname (e.g., `mail.wtg.zone`)
- `smtp_from`: Sender address (e.g., `ratatosk@wtg.zone`)
- `smtp_to`: Recipient address or semicolon-separated list

### 2. Build HTML email body by template

#### task-summary

Subject: `Ratatosk: {jobNumber} - {status}`

```powershell
$prLinksHtml = ($data.prUrls | ForEach-Object { "<li><a href='$_'>$_</a></li>" }) -join ""

$subject = "Ratatosk: $($data.jobNumber) - $($data.status)"
$body = @"
<html>
<body style="font-family: Segoe UI, Arial, sans-serif; color: #333;">
<h2>Task Summary: $($data.jobNumber)</h2>
<table style="border-collapse: collapse; width: 100%; max-width: 600px;">
  <tr><td style="padding: 6px; font-weight: bold;">Job Number</td><td style="padding: 6px;">$($data.jobNumber)</td></tr>
  <tr><td style="padding: 6px; font-weight: bold;">Type</td><td style="padding: 6px;">$($data.taskType)</td></tr>
  <tr><td style="padding: 6px; font-weight: bold;">Description</td><td style="padding: 6px;">$($data.description)</td></tr>
  <tr><td style="padding: 6px; font-weight: bold;">Zone</td><td style="padding: 6px;">$($data.zone)</td></tr>
  <tr><td style="padding: 6px; font-weight: bold;">Status</td><td style="padding: 6px;">$($data.status)</td></tr>
  <tr><td style="padding: 6px; font-weight: bold;">Duration</td><td style="padding: 6px;">$($data.duration)</td></tr>
</table>
<h3>Pull Requests</h3>
<ul>$prLinksHtml</ul>
</body>
</html>
"@
```

#### daily-report

Subject: `Ratatosk Daily Report - {date}`

```powershell
$workerRows = $data.workers | ForEach-Object {
    "<tr>
        <td style='padding: 6px; border: 1px solid #ddd;'>$($_.name)</td>
        <td style='padding: 6px; border: 1px solid #ddd;'>$($_.zone)</td>
        <td style='padding: 6px; border: 1px solid #ddd;'>$($_.status)</td>
        <td style='padding: 6px; border: 1px solid #ddd;'>$($_.jobNumber)</td>
        <td style='padding: 6px; border: 1px solid #ddd;'>$($_.completedCount)</td>
        <td style='padding: 6px; border: 1px solid #ddd;'>$($_.failedCount)</td>
    </tr>"
}

$subject = "Ratatosk Daily Report - $($data.date)"
$body = @"
<html>
<body style="font-family: Segoe UI, Arial, sans-serif; color: #333;">
<h2>Ratatosk Daily Report - $($data.date)</h2>
<p><strong>Completed:</strong> $($data.totalCompleted) | <strong>Failed:</strong> $($data.totalFailed) | <strong>Queued:</strong> $($data.totalQueued)</p>
<table style="border-collapse: collapse; width: 100%;">
  <thead>
    <tr style="background-color: #0078d4; color: white;">
      <th style="padding: 8px; border: 1px solid #ddd;">Worker</th>
      <th style="padding: 8px; border: 1px solid #ddd;">Zone</th>
      <th style="padding: 8px; border: 1px solid #ddd;">Status</th>
      <th style="padding: 8px; border: 1px solid #ddd;">Current Job</th>
      <th style="padding: 8px; border: 1px solid #ddd;">Completed</th>
      <th style="padding: 8px; border: 1px solid #ddd;">Failed</th>
    </tr>
  </thead>
  <tbody>
    $($workerRows -join "`n")
  </tbody>
</table>
</body>
</html>
"@
```

#### failed-alert

Subject: `[ALERT] Ratatosk Task Failed: {jobNumber}`

```powershell
$subject = "[ALERT] Ratatosk Task Failed: $($data.jobNumber)"
$body = @"
<html>
<body style="font-family: Segoe UI, Arial, sans-serif; color: #333;">
<div style="background-color: #fde7e9; border-left: 4px solid #d13438; padding: 12px; margin-bottom: 16px;">
  <h2 style="color: #d13438; margin-top: 0;">Task Failed</h2>
</div>
<table style="border-collapse: collapse; width: 100%; max-width: 600px;">
  <tr><td style="padding: 6px; font-weight: bold;">Job Number</td><td style="padding: 6px;">$($data.jobNumber)</td></tr>
  <tr><td style="padding: 6px; font-weight: bold;">Type</td><td style="padding: 6px;">$($data.taskType)</td></tr>
  <tr><td style="padding: 6px; font-weight: bold;">Zone</td><td style="padding: 6px;">$($data.zone)</td></tr>
  <tr><td style="padding: 6px; font-weight: bold;">Worker</td><td style="padding: 6px;">$($data.worker)</td></tr>
  <tr><td style="padding: 6px; font-weight: bold;">Timestamp</td><td style="padding: 6px;">$($data.timestamp)</td></tr>
  <tr><td style="padding: 6px; font-weight: bold;">Error</td><td style="padding: 6px; color: #d13438;">$($data.error)</td></tr>
</table>
<h3>Logs</h3>
<pre style="background-color: #f4f4f4; padding: 12px; border-radius: 4px; overflow-x: auto; font-size: 12px;">$($data.logs)</pre>
</body>
</html>
"@
```

### 3. Send via PowerShell

```powershell
$recipients = $smtpTo -split ";" | ForEach-Object { $_.Trim() } | Where-Object { $_ }

try {
    Send-MailMessage `
        -From $smtpFrom `
        -To $recipients `
        -Subject $subject `
        -Body $body `
        -BodyAsHtml `
        -SmtpServer $smtpServer `
        -Encoding UTF8

    Write-Host "Email sent successfully ($templateName -> $smtpTo)"
    [PSCustomObject]@{ success = $true; template = $templateName }
} catch {
    Write-Warning "Failed to send email: $_"
    [PSCustomObject]@{ success = $false; template = $templateName; error = $_.Exception.Message }
}
```

### 4. Return result

Returns an object with:
- **success** (boolean): Whether the email was sent.
- **template** (string): The template name that was used.
- **error** (string, optional): Error message if sending failed.

## Error Handling

- If `config.local.yaml` is missing or any required SMTP key is absent, throw immediately.
- If `Send-MailMessage` fails (bad server, auth, etc.), catch the error and return a failure result.
- Multiple recipients are supported via semicolon-separated `smtp_to` values.

## Notes

- `Send-MailMessage` is deprecated in PowerShell 7+ but remains functional. For future-proofing, the implementation can be swapped to `System.Net.Mail.SmtpClient`:

```powershell
$smtp = New-Object System.Net.Mail.SmtpClient($smtpServer)
$mail = New-Object System.Net.Mail.MailMessage
$mail.From = $smtpFrom
$recipients | ForEach-Object { $mail.To.Add($_) }
$mail.Subject = $subject
$mail.Body = $body
$mail.IsBodyHtml = $true
$smtp.Send($mail)
$mail.Dispose()
$smtp.Dispose()
```

