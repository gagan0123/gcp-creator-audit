# GCP Creator Audit

A robust Bash script to audit Google Cloud Platform (GCP) projects within an Organization. It identifies the original **Creator** of each project by querying Audit Logs and falls back to listing current **Owners** if logs are expired or unavailable.

## 🚀 Features

- **Deep Audit:** Retrieves `Project ID`, `Creation Date`, `Creator Email` (from logs), and `Current Owners` (from IAM).
- **Smart Fallback:** If Audit Logs are expired (>400 days) or disabled, it automatically fetches the current IAM Owners as a backup.
- **Self-Healing Permissions:**
    - Automatically detects `PERMISSION_DENIED` errors when reading logs.
    - Triggers a background job to grant the `roles/logging.viewer` role to the active user at the Organization level.
    - Queues failed projects and retries them automatically once permissions propagate.
- **Auto-Detection:** Automatically detects the currently authenticated `gcloud` user identity.
- **Real-time Progress:** Displays a progress bar with an Estimated Time Remaining (ETR) calculation.
- **Zero Dependencies:** Uses standard `awk` for math, eliminating the need for external tools like `bc`.
- **CSV Export:** Outputs clean, machine-readable CSV data suitable for Google Sheets or Excel.

## 📋 Prerequisites

1. **Google Cloud SDK (`gcloud`)**: Must be installed and authenticated.
2. **Organization Access**: You must be an **Organization Administrator** (to allow the script to self-fix permissions) or already have `roles/logging.viewer` on the organization.
3. **Bash Environment**: Compatible with Cloud Shell, Linux, and macOS.

## 🛠️ Usage

### 1. Make Executable

First, ensure the script is executable:

```
chmod +x audit.sh

```

### 2. Basic Run

Run the script by providing your Organization ID. The script will automatically detect your user email and generate `output.csv`.

```
./audit.sh --org 123456789012

```

### 3. Custom Output

Specify a custom filename for the CSV report using the `--out` flag.

```
./audit.sh --org 123456789012 --out my-audit-report.csv

```

### 4. Help Menu

View all available options:

```
./audit.sh --help

```

## 🧠 Design Choices & Architecture

### The "Permission Paradox"

Even as an Organization Admin, you do not automatically have permission to view the data (logs) inside every project; you only control the hierarchy.

- **Solution:** The script implements a **"Just-in-Time" self-fix**. If it hits a permission error, it attempts to grant `logging.viewer` to your active user identity at the Org level.

### Asynchronous Propagation

IAM changes take 60-120 seconds to propagate across Google Cloud.

- **Solution:** Instead of blocking execution, the script:
    1. Triggers the IAM fix in the background.
    2. Moves the failed project to a **Retry Queue**.
    3. Continues processing other accessible projects.
    4. Processes the Retry Queue at the end, ensuring enough time has passed for propagation.

### "Creator" vs. "Owner"

- **Creator:** Derived from `cloudaudit.googleapis.com` logs (`methodName:CreateProject`). This is the immutable source of truth but is **deleted after 400 days**.
- **Owner:** Derived from IAM Policy (`roles/owner`). This is mutable (owners change) but is always available.
- **Strategy:** The script prioritizes the Creator. If logs are gone (labeled `Unknown: Logs Expired`), it provides the Current Owner so you have a point of contact.

## 📊 Output Format

The script generates a CSV with the following columns:

| Column                  | Description                                                                                                    |
|-------------------------|----------------------------------------------------------------------------------------------------------------|
| **Project ID**          | The unique ID of the GCP project.                                                                              |
| **Created**             | Timestamp of creation (ISO 8601).                                                                              |
| **Creator (from Logs)** | The email of the user who ran `CreateProject`. Values include email, `Unknown: Logs Expired`, or error states. |
| **Current Owner(s)**    | Comma-separated list of current owners from IAM policy.                                                        |

## ⚠️ Known Limitations

- **Log Retention:** Projects created >400 days ago will never show a Creator, as Google permanently purges these logs.
- **Deleted Projects:** The script currently lists active projects. Projects pending deletion are excluded by standard `gcloud` listing behavior.

## 📄 License

This project is licensed under the **GNU General Public License v3.0 (GPLv3)**.
