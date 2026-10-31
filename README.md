# AWSBar

AWSBar is a macOS menu bar app for checking and controlling AWS resources. It runs the `aws` CLI you already have installed. It makes no network calls of its own and collects no analytics.

It needs macOS 14 or later.

**Download:** [awsbar.vercel.app](https://awsbar.vercel.app) has the disk image. Open it and drag AWSBar to Applications. The app isn't notarized yet, so the first time, right-click it and choose Open.

To build it yourself: `brew install xcodegen`, then `xcodegen generate` and open `AWSBar.xcodeproj`.

## What it does

- Reads profiles from `~/.aws/config` and `~/.aws/credentials`. It also honors `AWS_CONFIG_FILE` and `AWS_SHARED_CREDENTIALS_FILE`.
- Runs `aws sts get-caller-identity` for the selected profile and shows the account, role or user, and region.
- If that call fails, it shows a Login button for SSO profiles (`aws sso login --profile <name>`) and console-login profiles (`aws login --profile <name>`). Profiles with static keys get only Retry.
- Shows what AWS has charged the account this month, and in total since the first month with a charge (up to 12 months back). See [Costs and active services](#costs-and-active-services).
- Lists every service the account used this month or last month, with what each one cost.
- Lists EC2 instances, RDS instances, ECS services, Lambda functions, and S3 buckets in collapsible sections. EC2, RDS, and ECS rows have a status dot.
- Starts, stops, and restarts EC2 instances, RDS instances, and ECS services. The buttons appear when you point at a row, and the same actions are in its right-click menu. Stop and restart ask for confirmation first. See [Confirmation](#confirmation).
- Opens a shell window for a running EC2 instance. Double-click its row, or right-click it and choose Open Shell. See [EC2 shell](#ec2-shell).
- Opens a browser window for an S3 bucket. Double-click its row, or right-click it and choose Browse. See [S3 browser](#s3-browser).
- Runs any `aws` command you type in the Run tab and shows its output. It adds `--profile` and `--region` unless you set them yourself.
- Logs every CLI call in the History tab. The log on disk stores only the command line, exit code, time, and duration. It never stores output. The tab leaves out the leading `aws` and the `--profile`, `--region`, and `--output json` flags that AWSBar adds; point at a row to see the full command. Values after flags such as `--secret-string` or `--password`, and arguments that contain words like password, secret, or token, are masked before saving. Other inline credentials in a command typed in the Run tab are saved as typed. The file is `~/Library/Application Support/AWSBar/history.json`, readable only by you.

Some actions behave differently by service.

- An RDS instance that belongs to an Aurora cluster starts and stops its whole cluster, because AWS doesn't allow stopping a single Aurora instance.
- An ECS service stops by scaling its desired count to 0 and starts by scaling to 1. Restart forces a new deployment.
- Lambda functions and S3 buckets have no running state, so their rows have no action buttons.

## Costs and active services

The header shows this month's charges, and the total since the first month with a charge in the last 12 months. Point at the line to see last month's charges and when the numbers were checked. The Active services section lists every service with usage this month or last month, most expensive first, including services that are free so far. Tax is counted in the totals but isn't listed.

Both come from one `aws ce get-cost-and-usage` call. Keep these points in mind:

- Amounts are before credits and refunds, so they show what your usage cost even when credits pay for it.
- AWS charges $0.01 for each Cost Explorer request. AWSBar loads the numbers when you sign in and then reuses them for 6 hours. The header's Refresh button doesn't fetch them again in that time. The section's own Refresh button and switching profiles always do.
- Cost Explorer updates a few times a day, so the latest usage can take up to a day to appear. Services that never bill, such as IAM, don't appear.
- Your credentials need `ce:GetCostAndUsage`. Cost Explorer must also be turned on for the account. It is on by default after someone opens Cost Explorer in the console.

## Confirmation

Start runs as soon as you click it. Stop and restart open a confirmation row under the resource first.

- For an EC2 instance or an RDS instance, type the resource's name into the field. The field shows the name as a placeholder. The red button stays disabled, and Return does nothing, until the text matches exactly. For an Aurora member, stop names the whole cluster, so you type the cluster's ID instead.
- For an ECS service, click the red button. Stop only scales the service to 0, and restart only starts a new deployment, so one click is enough.
- Press Escape or click Cancel to close the row without doing anything. Double-clicking the row doesn't open a window while the row is open.

## EC2 shell

The shell window is an interactive terminal on the instance. It runs `aws ssm start-session` through AWS Systems Manager (SSM) Session Manager, so the instance needs no SSH key pair or open port. Everything you type, and everything the instance prints, goes over SSM.

### Install the Session Manager plugin

The aws CLI needs Amazon's Session Manager plugin to open a session. Install it once:

```sh
brew install --cask session-manager-plugin
```

If the plugin is missing, the window says so and shows the command above with a Retry button. AWSBar looks for `session-manager-plugin` in Homebrew's folders, in `/usr/local/sessionmanagerplugin/bin` (where Amazon's own installer puts it), and on your login shell's PATH.

### What the session does

- It opens a root login shell with `sudo -i`. The shell starts in the folder of the first running Docker Compose project, so `docker compose ps` and `docker compose logs` work right away. AWSBar finds that folder from the `com.docker.compose.project.working_dir` label of a running container. If no Compose project is running, or Docker isn't installed, the shell starts in root's home folder.
- It works like Terminal. Interactive programs such as `docker exec -it`, `htop`, and `vim` work, output appears as it arrives, and resizing the window resizes the remote terminal.
- The header shows the instance's name and ID, the profile, the region, and the status: Connecting, Connected, or Session ended with the exit code.
- When the session ends, for example after you type `exit`, the window stays open. Click Reconnect to start a new session.
- Closing the window ends the session. AWSBar hangs up aws and the plugin, the way closing a Terminal window does, and runs `aws ssm terminate-session`, so the remote shell doesn't stay open until SSM's idle timeout.

The window keeps the profile and region that were selected when you opened it. Changing the profile in the menu doesn't affect windows that are already open.

### Requirements

- The instance runs Linux with the SSM agent installed and running. Recent Amazon Linux and Ubuntu AMIs include the agent. Windows instances aren't supported, because the session starts bash.
- The instance has an instance profile with the `AmazonSSMManagedInstanceCore` policy.
- The user the agent runs sessions as, `ssm-user` unless your Session Manager preferences set Run As, can run `sudo` without a password. The agent sets this up for `ssm-user`.
- Your credentials allow `ssm:StartSession` on the instance and on the `AWS-StartInteractiveCommand` document, and `ssm:TerminateSession` on your own sessions.

### History

History records the `start-session` command line, with its exit code and how long the session lasted, when the session ends. If you close the window while the session is open, History also records the `terminate-session` call. AWSBar never logs what you type or what the instance prints. If your account turns on Session Manager logging, AWS itself saves the session's output to S3 or CloudWatch Logs.

Shell windows don't reopen when the app restarts.

## S3 browser

The browser window lists a bucket's folders and files, folders first. It's view-only, so it can't upload, delete, or rename anything.

- Open a folder by double-clicking it or by clicking it in the path at the top. Back (Command-[) returns to the previous folder, and Up (Command-Up Arrow) opens the enclosing folder. Refresh (Command-R) lists the folder again. A key with `//` in it has a folder with no name, which shows as (empty).
- A folder lists 1,000 items at a time, counting folders and files together. Click Load More at the bottom to list the next 1,000.
- Select or double-click a file to preview it with Quick Look. Files over 25 MB aren't previewed until you click Preview Anyway, or right-click the file and choose Preview.
- Click Download… to save a copy, or right-click a row and choose Copy S3 URI to copy its `s3://bucket/key` address. A saved copy is quarantined like a file from a web browser, so macOS checks it before it opens or runs.

Previews are downloaded into a temporary folder that belongs to the window and only you can read. A preview that fails, or that you leave before it finishes, is deleted right away. The folder is deleted when the window closes or the app quits. If the app crashes or is force quit, it deletes the folders that are left the next time it starts. A download you start with Download… keeps running if you close the window.

The window keeps the profile and region that were selected when you opened it. Your credentials need `s3:ListBucket` and `s3:GetObject` on the bucket.

History records each listing and each Download…, including the folder or file name. The aws CLI reads a value that starts with `file://` or `fileb://` as a local file to load, so a folder whose name starts that way is listed with `--cli-input-json`, and such a file is downloaded with `aws s3 cp` instead of `aws s3api get-object`. It doesn't record previews, because moving through a folder with the arrow keys would add an entry for every file. Bucket windows don't reopen when the app restarts.

## Build

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen). The generated `AWSBar.xcodeproj` is checked in, so you only need XcodeGen if you change `project.yml`. The shell window's terminal is [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), which Xcode fetches through Swift Package Manager on the first build.

```sh
brew install xcodegen   # only needed to regenerate the project
xcodegen generate
open AWSBar.xcodeproj
```

To build and test from the command line, run:

```sh
xcodebuild -project AWSBar.xcodeproj -scheme AWSBar -derivedDataPath build/dd test
```

Debug builds are ad-hoc signed and run locally without an Apple Developer account.

## Release (Developer ID and notarization)

The app is not sandboxed, because it runs CLIs and reads `~/.aws`. Release builds use the hardened runtime and sign with your `Developer ID Application` certificate.

1. Install a Developer ID Application certificate in your login keychain.
2. Store notarization credentials once:

   ```sh
   xcrun notarytool store-credentials awsbar-notary \
     --apple-id you@example.com --team-id ABCDE12345 --password <app-specific-password>
   ```

3. Build, sign, notarize, and staple:

   ```sh
   TEAM_ID=ABCDE12345 NOTARY_PROFILE=awsbar-notary scripts/release.sh
   ```

The script writes `build/release/AWSBar.zip`, which contains the stapled app.

## Debug snapshots

Debug builds accept `-snapshot <dir>`. The app loads its data, writes a PNG of each tab in light and dark mode into `<dir>`, and quits. This lets you check the popover without clicking the menu bar icon.

```sh
build/dd/Build/Products/Debug/AWSBar.app/Contents/MacOS/AWSBar -snapshot /tmp/awsbar-shots
```

Add `-snapshotBucket <bucket>` to render the S3 browser instead. The app lists the bucket root, or the folder given with `-snapshotPrefix <prefix>` (for example `logs/2026/`), waits up to 60 seconds for the listing, and writes `Bucket-light.png` and `Bucket-dark.png`. It doesn't preview or download any file.

## Layout

- `AWSBar/Core` has the process runner, the profile parser, the history store, and the shared resource model.
- `AWSBar/Services` has one provider per service. Each provider lists resources and performs actions through the CLI.
- `AWSBar/App` has the app entry point and `AppState`, which owns the selected profile, sign-in state, and per-section data. It also has `TerminalSession`, which runs the `aws ssm start-session` process for one shell window. `BucketBrowser` holds the folder, listing, and preview state for one S3 browser window.
- `AWSBar/Views` has the SwiftUI views.
