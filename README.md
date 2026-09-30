# DistroDemo

A minimal two-device demo of OpenHarmony distributed features, written in
ArkTS for API 23 (OpenHarmony 6.1). It was used to validate cross-device
operation between two Oniro phones (Volla Phone Plinius ↔ Volla X23) over
WiFi, but it runs on any pair of OpenHarmony devices on the same network.

One screen shows three things:

| Feature | API | What the app does |
|---|---|---|
| Device pairing | `@kit.DistributedServiceKit` (`distributedDeviceManager`) | **Pair** discovers nearby devices and binds the first untrusted one (PIN pairing through the system `devicemanagerui`). The header lists trusted peers that are online. |
| Shared note | `@kit.ArkData` (`distributedKVStore`) | A single-version KV store with `autoSync`. **Share** writes a note and pushes it to every peer; the other device updates live and shows which device wrote it. |
| Shared files | `@kit.CoreFileKit` (`fileIo.connectDfs`, `distributedFilesDir`) | **Connect** opens the distributed file system link to peers; **Write file** drops `hello_from_<device>.txt` into the app's distributed files dir; the list shows local and remote files. |

Status messages go to the bottom of the screen and to hilog
(domain `0x0d15`, tag `DistroDemo`).

## Build and install

This repository carries no signing material. Generate signing configs for
your own keys first:

```bash
oniro-app sign          # writes signingConfigs into build-profile.json5
oniro-app build         # or: hvigorw assembleHap
oniro-app app install   # install on the connected device
oniro-app app launch
```

Install the HAP on **both** devices.

## Running the demo

1. Put both devices on the same WiFi network and keep their screens
   **unlocked**. The sink only shows the trust/PIN dialog while unlocked,
   so a long screen timeout helps.
2. Launch DistroDemo on both and grant `DISTRIBUTED_DATASYNC` when asked.
3. On one device tap **Pair** and confirm the PIN shown on the other. The
   header turns green: `Connected: <peer>`.
4. Type a note and tap **Share**. It appears on the peer.
5. Tap **Connect**, then **Write file** on each device, then **Refresh**.
   Each side lists the other's file.

## Gotchas

These showed up on the Oniro bring-up. Most are general OpenHarmony
behaviour.

- **Bundle name is `com.example.myapplication` on purpose.** Pairing from an
  ordinary app gives only APP-level trust, which system services such as
  `distributedfiledaemon` ignore. Device Manager's development whitelist
  (`DEVICE_MANAGER_COMMON_FLAG`) grants USER-level trust to that bundle
  name, which the distributed file system needs. This is a development hook
  only; don't ship it.
- **File security labels.** Development devices report security level SL1,
  and hmdfs refuses to open remote files whose data label is higher
  (`devsl permission denied`). The app labels its files `s1` with
  `securityLabel.setSecurityLabelSync`.
- **Remote files appear only after a restart.** The app's distributed files
  dir is a bind mount made at app start, and hmdfs computes the merged view
  once. If the peer comes online after the app started, restart the app.
  The DFS link lasts only as long as the app that called `connectDfs`.
- **Permission denied?** If `DISTRIBUTED_DATASYNC` was refused, grant it from
  a shell:
  `hdc shell atm perm -g -i <tokenId> -p ohos.permission.DISTRIBUTED_DATASYNC`.
- **Softbus needs a device UDID.** If the devices never see each other, check
  that `const.product.devUdid` is set (`param get const.product.devUdid`).
  On the Oniro hybris devices it comes from `ohos.boot.sn`.

## Layout

```
AppScope/                     app-level config and resources
entry/src/main/ets/pages/Index.ets    the whole demo (UI + distributed logic)
entry/src/main/ets/entryability/      UIAbility boilerplate
entry/src/main/module.json5           permissions (DISTRIBUTED_DATASYNC)
```
