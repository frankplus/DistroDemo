import { common, abilityAccessCtrl } from '@kit.AbilityKit';
import { distributedKVStore } from '@kit.ArkData';
import { distributedDeviceManager } from '@kit.DistributedServiceKit';
import { fileIo as fs, securityLabel } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG = 'DistroDemo';
const DOMAIN = 0x0d15;
const STORE_ID = 'distro_demo_store';
const NOTE_KEY = 'note';

interface DiscoveredDevice {
  device: distributedDeviceManager.DeviceBasicInfo;
}

interface PeerFile {
  name: string;
  text: string;
}

@Entry
@Component
struct Index {
  @State localName: string = '';
  @State peers: distributedDeviceManager.DeviceBasicInfo[] = [];
  @State draft: string = '';
  @State sharedNote: string = '(nothing shared yet)';
  @State noteOrigin: string = '';
  @State dfsStatus: string = 'not connected';
  @State files: PeerFile[] = [];
  @State log: string = '';
  private ctx: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
  private dm: distributedDeviceManager.DeviceManager | undefined = undefined;
  private kvStore: distributedKVStore.SingleKVStore | undefined = undefined;

  private say(msg: string): void {
    hilog.info(DOMAIN, TAG, '%{public}s', msg);
    this.log = msg;
  }

  async aboutToAppear(): Promise<void> {
    try {
      await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(this.ctx,
        ['ohos.permission.DISTRIBUTED_DATASYNC']);
    } catch (e) {
      this.say(`permission request failed: ${JSON.stringify(e)}`);
    }
    this.initDeviceManager();
    await this.initKvStore();
    this.listFiles();
  }

  private initDeviceManager(): void {
    try {
      this.dm = distributedDeviceManager.createDeviceManager(this.ctx.abilityInfo.bundleName);
      this.localName = this.dm.getLocalDeviceName();
      this.refreshPeers();
      this.dm.on('deviceStateChange', () => this.refreshPeers());
    } catch (e) {
      this.say(`device manager: ${(e as BusinessError).message}`);
    }
  }

  // Discover nearby devices and bind the first untrusted one (PIN pairing via devicemanagerui).
  private pair(): void {
    if (this.dm === undefined) {
      return;
    }
    const dm = this.dm;
    let bound = false;
    dm.on('discoverSuccess', (data: DiscoveredDevice) => {
      const dev: distributedDeviceManager.DeviceBasicInfo = data.device;
      if (bound || this.peers.some((p) => p.deviceId === dev.deviceId)) {
        return;
      }
      bound = true;
      this.say(`found ${dev.deviceName}, pairing…`);
      try {
        dm.stopDiscovering();
      } catch (e) {
        // already stopped
      }
      dm.bindTarget(dev.deviceId, { 'bindType': 1, 'targetPkgName': this.ctx.abilityInfo.bundleName,
        'appName': 'DistroDemo' }, (err: BusinessError) => {
        if (err) {
          this.say(`pairing failed: ${err.message} (${err.code})`);
          bound = false;
          return;
        }
        this.say(`paired with ${dev.deviceName}`);
        this.refreshPeers();
      });
    });
    try {
      dm.startDiscovering({ 'discoverTargetType': 1 });
      this.say('searching for devices…');
    } catch (e) {
      this.say(`discovery: ${(e as BusinessError).message}`);
    }
  }

  private refreshPeers(): void {
    if (this.dm === undefined) {
      return;
    }
    try {
      this.peers = this.dm.getAvailableDeviceListSync();
      this.say(`${this.peers.length} trusted peer(s) online`);
    } catch (e) {
      this.say(`peer list: ${(e as BusinessError).message}`);
    }
  }

  private async initKvStore(): Promise<void> {
    try {
      const manager = distributedKVStore.createKVManager({
        context: this.ctx,
        bundleName: this.ctx.abilityInfo.bundleName
      });
      this.kvStore = await manager.getKVStore<distributedKVStore.SingleKVStore>(STORE_ID, {
        createIfMissing: true,
        encrypt: false,
        backup: false,
        autoSync: true,
        kvStoreType: distributedKVStore.KVStoreType.SINGLE_VERSION,
        securityLevel: distributedKVStore.SecurityLevel.S1
      });
      this.kvStore.on('dataChange', distributedKVStore.SubscribeType.SUBSCRIBE_TYPE_ALL,
        (change: distributedKVStore.ChangeNotification) => {
          const entries = change.insertEntries.concat(change.updateEntries);
          for (const entry of entries) {
            if (entry.key === NOTE_KEY) {
              this.showNote(entry.value.value as string, change.deviceId);
            }
          }
        });
      this.kvStore.on('syncComplete', (results: Array<[string, number]>) => {
        this.say(`sync complete: ${JSON.stringify(results)}`);
      });
      try {
        const stored = await this.kvStore.get(NOTE_KEY);
        this.showNote(stored as string, '');
      } catch (e) {
        // no note stored yet
      }
      this.say('KV store ready');
    } catch (e) {
      this.say(`KV store: ${JSON.stringify(e)}`);
    }
  }

  // The stored value is "<text>\u0001<device name>" so the receiver can show who wrote it.
  private showNote(raw: string, deviceId: string): void {
    const sep = raw.lastIndexOf('\u0001');
    this.sharedNote = sep >= 0 ? raw.substring(0, sep) : raw;
    const from = sep >= 0 ? raw.substring(sep + 1) : '';
    this.noteOrigin = from.length > 0 ? `written on ${from}` : '';
    if (deviceId.length > 0) {
      this.say('note updated by remote device');
    }
  }

  private async shareNote(): Promise<void> {
    if (this.kvStore === undefined || this.draft.length === 0) {
      return;
    }
    const value = `${this.draft}\u0001${this.localName}`;
    await this.kvStore.put(NOTE_KEY, value);
    this.showNote(value, '');
    const ids: string[] = this.peers.map((p) => p.networkId ?? '').filter((id) => id.length > 0);
    if (ids.length > 0) {
      try {
        this.kvStore.sync(ids, distributedKVStore.SyncMode.PUSH_PULL);
        this.say(`note pushed to ${ids.length} peer(s)`);
      } catch (e) {
        this.say(`sync: ${(e as BusinessError).message}`);
      }
    }
    this.draft = '';
  }

  private async connectDfs(): Promise<void> {
    for (const peer of this.peers) {
      const id = peer.networkId ?? '';
      try {
        await fs.connectDfs(id, {
          onStatus: (networkId: string, status: number) => {
            this.dfsStatus = `status ${status} from ${networkId.substring(0, 6)}`;
          }
        });
        this.dfsStatus = `connected to ${peer.deviceName}`;
      } catch (e) {
        this.dfsStatus = `connect failed: ${JSON.stringify(e)}`;
      }
    }
    this.listFiles();
  }

  private writeFile(): void {
    const dir = this.ctx.distributedFilesDir;
    const name = `hello_from_${this.localName.replace(new RegExp('\\s+', 'g'), '_')}.txt`;
    const file = fs.openSync(`${dir}/${name}`, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    fs.writeSync(file.fd, `Hi! Written on ${this.localName} at ${new Date().toLocaleTimeString()}`);
    fs.closeSync(file);
    // Peers only open files whose data label fits their device security level (dev devices are SL1).
    securityLabel.setSecurityLabelSync(`${dir}/${name}`, 's1');
    this.say(`wrote ${name}`);
    this.listFiles();
  }

  private listFiles(): void {
    const dir = this.ctx.distributedFilesDir;
    const out: PeerFile[] = [];
    try {
      for (const name of fs.listFileSync(dir)) {
        let text = '';
        try {
          text = fs.readTextSync(`${dir}/${name}`);
        } catch (e) {
          text = `(unreadable: ${(e as BusinessError).message})`;
        }
        out.push({ name: name, text: text });
      }
    } catch (e) {
      this.say(`list: ${(e as BusinessError).message}`);
    }
    this.files = out;
  }

  build() {
    Scroll() {
      Column({ space: 14 }) {
        Text('Distributed Demo').fontSize(28).fontWeight(FontWeight.Bold)
        Text(`This device: ${this.localName}`).fontSize(16)
        Text(this.peers.length > 0
          ? `Connected: ${this.peers.map((p) => p.deviceName).join(', ')}`
          : 'No trusted peer online')
          .fontSize(16)
          .fontColor(this.peers.length > 0 ? '#1b7f3b' : '#b3261e')

        Column({ space: 8 }) {
          Text('Shared note (distributed KV store)').fontSize(18).fontWeight(FontWeight.Medium)
          Text(this.sharedNote).fontSize(22).fontColor('#0a59f7')
          Text(this.noteOrigin).fontSize(13).fontColor('#666666')
          Row({ space: 8 }) {
            TextInput({ placeholder: 'Type a note…', text: this.draft })
              .id('noteInput')
              .layoutWeight(1)
              .onChange((v: string) => {
                this.draft = v;
              })
            Button('Share').id('shareBtn').onClick(() => {
              this.shareNote();
            })
          }
        }
        .padding(12)
        .borderRadius(12)
        .backgroundColor('#f1f3f5')
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        Column({ space: 8 }) {
          Text('Shared files (distributed file system)').fontSize(18).fontWeight(FontWeight.Medium)
          Text(`DFS: ${this.dfsStatus}`).fontSize(13).fontColor('#666666')
          Row({ space: 8 }) {
            Button('Connect').id('connectBtn').onClick(() => {
              this.connectDfs();
            })
            Button('Write file').id('writeBtn').onClick(() => {
              this.writeFile();
            })
            Button('Pair').id('pairBtn').onClick(() => {
              this.pair();
            })
            Button('Refresh').id('refreshBtn').onClick(() => {
              this.refreshPeers();
              this.listFiles();
            })
          }
          ForEach(this.files, (f: PeerFile) => {
            Column() {
              Text(f.name).fontSize(14).fontWeight(FontWeight.Medium)
              Text(f.text).fontSize(13).fontColor('#444444')
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
          }, (f: PeerFile) => f.name + f.text)
        }
        .padding(12)
        .borderRadius(12)
        .backgroundColor('#f1f3f5')
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        Text(this.log).fontSize(12).fontColor('#888888')
      }
      .padding({ left: 16, right: 16, top: 48, bottom: 32 })
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
  }
}
