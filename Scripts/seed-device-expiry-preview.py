#!/usr/bin/env python3
"""Create isolated, synthetic SignFlow state for the device-expiry UI preview."""
import argparse
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--output", required=True, type=Path)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
project_id = "11111111-1111-4111-8111-111111111111"
state_file = args.output / "state.json"
if state_file.exists():
    try:
        existing = json.loads(state_file.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise SystemExit(f"Refusing to overwrite unreadable state: {error}")
    projects = existing.get("projects", [])
    if len(projects) != 1 or projects[0].get("id") != project_id or projects[0].get("path") != "/private/tmp/SignFlowPreview/Preview.xcodeproj":
        raise SystemExit(f"Refusing to overwrite non-preview state: {state_file}")

install_id = "22222222-2222-4222-8222-222222222222"
query_id = "33333333-3333-4333-8333-333333333333"
install_time = "2026-10-27T14:26:11Z"
query_time = "2026-10-27T15:20:42Z"


def bundle(platform, app_id, expires, parent=None):
    profile = {"uuid": f"{app_id}-profile", "name": "Synthetic Development",
               "teamIDs": ["PREVIEW"], "applicationIdentifier": f"PREVIEW.{app_id}",
               "creationDate": "2026-10-27T12:53:00Z", "expirationDate": expires,
               "provisionedDevices": ["preview-phone", "preview-watch"], "entitlements": {},
               "certificates": [], "provisionsAllDevices": False, "isDevelopment": True}
    value = {"path": f"/private/tmp/SignFlowPreview/{app_id}.app", "bundleID": app_id,
             "displayName": platform, "version": "1.0", "buildVersion": "1", "platform": platform,
             "isExtension": False, "teamID": "PREVIEW", "codeSignatureValid": True,
             "validationMessage": "Synthetic preview", "profile": profile, "inspectedAt": install_time}
    if parent:
        value["parentBundleID"] = parent
    return value


def deployment(platform, app_id, device, time, source=None):
    value = {"deviceID": device, "deviceName": f"Preview {platform}", "bundleID": app_id,
             "platform": platform, "state": "installed", "installedVersion": "1.0", "installedBuild": "1",
             "verifiedAt": time, "deviceSignatureVerified": False, "message": "合成预览记录"}
    if source:
        value["sourceTaskID"] = source
    return value


phone = bundle("iOS", "preview.app", "2026-11-03T12:53:47Z")
watch = bundle("watchOS", "preview.app.watch", "2026-11-03T11:23:43Z", "preview.app")
signatures = [phone, watch]
installs = [deployment("iOS", "preview.app", "phone", install_time, install_id),
            deployment("watchOS", "preview.app.watch", "watch", install_time, install_id)]
checked = [deployment("iOS", "preview.app", "phone", query_time),
           deployment("watchOS", "preview.app.watch", "watch", query_time)]


def target(name, app_id, platform, kind):
    return {"name": name, "bundleID": app_id, "platform": platform, "kind": kind,
            "productType": "application", "teamID": "PREVIEW", "automaticSigning": True, "deploymentTarget": "17"}


project = {"id": project_id, "name": "预览项目", "path": "/private/tmp/SignFlowPreview/Preview.xcodeproj",
           "kind": "project", "scheme": "Preview", "configuration": "Debug", "teamOverride": "",
           "allowProvisioningUpdates": True, "allowDeviceRegistration": False, "acceptExistingInstallRisk": False,
           "targets": [target("Preview", "preview.app", "iOS", "application"),
                       target("Preview Watch", "preview.app.watch", "watchOS", "watchApplication")],
           "phoneID": "phone", "watchID": "watch",
           "renewal": {"enabled": False, "intervalMinutes": 60, "advanceHours": 48, "maxRetries": 3,
                       "retryBaseSeconds": 60, "installAutomatically": True},
           "signatures": signatures, "deployments": checked, "importedAt": install_time}


def task(task_id, kind, evidence, new_signatures, time):
    return {"id": task_id, "projectID": project_id, "projectName": "预览项目", "kind": kind,
            "phase": "completed", "createdAt": time, "updatedAt": time, "finishedAt": time,
            "retryCount": 0, "automatic": False, "recovered": False, "oldSignatures": [],
            "newSignatures": new_signatures, "deployments": evidence, "summary": "合成预览记录", "events": []}


settings = {"appearance": "system", "language": "zh-Hans", "showMenuBar": False, "keepRunning": False,
            "automationEnabled": False, "automationPaused": True, "intervalMinutes": 60, "advanceHours": 48,
            "installAutomatically": False, "retryOffline": False, "xcodePath": "/private/tmp/SignFlowPreviewNoXcode",
            "defaultConfiguration": "Debug", "defaultProjectPath": "/private/tmp/SignFlowPreview",
            "derivedDataPath": "", "maxConcurrentTasks": 1, "logRetentionDays": 30,
            "notifyExpiry": False, "notifyInstall": False, "notifyRenewal": False, "notifyFailure": False,
            "notifyUserAction": False, "notifyDevice": False}
state = {"schemaVersion": 1, "projects": [project], "devices": [], "settings": settings,
         "tasks": [task(query_id, "verifyInstallation", checked, [], query_time),
                   task(install_id, "renew", installs, signatures, install_time)]}
state_file.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(state_file)
