enum AppLanguage { static var current: String? { nil }; static func effectiveLanguage(for code: String?) -> String? { "en" } }


@main struct TestRunner {
 @MainActor static func main() throws {
  let temp=FileManager.default.temporaryDirectory.appendingPathComponent("khua-config-contract-"+UUID().uuidString)
  try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
  defer { try? FileManager.default.removeItem(at:temp) }
  EnhancementProfileStore.testDirectory=temp
  var custom=EnhancementProfile();custom.configName="游戏";custom.interpolationEngineID="rife.metal";custom.modelID="rife-v4.26";custom.rate = .multiplier(3)
  try EnhancementProfileStore.saveNamed(custom)
  precondition(EnhancementProfileStore.resolvedID(custom)=="custom:游戏")
  var preset=EnhancementProfile();preset.configName="游戏";preset.configID="preset:game";preset.interpolationEngineID="apple.lowlatency"
  try EnhancementProfileStore.savePreset(preset,id:"preset:game")
  precondition(EnhancementProfileStore.loadNamed("游戏")==custom)
  precondition(EnhancementProfileStore.loadPreset("preset:game")==preset)
  custom.configID="custom:游戏";custom.outputWidth=1280;try EnhancementProfileStore.saveNamed(custom);try EnhancementProfileStore.save(custom)
  precondition(EnhancementProfileStore.load()==custom && EnhancementProfileStore.loadNamed("游戏")==custom)
  precondition(EnhancementProfileStore.checkNewName("") == .invalid)
  precondition(EnhancementProfileStore.checkNewName("Game") == .duplicate)
  precondition(EnhancementProfileStore.checkNewName("游戏") == .duplicate)
  precondition(EnhancementProfileStore.checkNewName("My Profile") == .valid)
  var metadata=EnhancementProfileStore.ConfigMetadata();metadata.titles["preset:game"]="我喜欢的游戏";metadata.hiddenPresets=["preset:anime"]
  try EnhancementProfileStore.saveMetadata(metadata)
  precondition(EnhancementProfileStore.metadata().titles["preset:game"]=="我喜欢的游戏")
  precondition(EnhancementProfileStore.metadata().hiddenPresets==["preset:anime"])
  metadata.hiddenPresets=[];try EnhancementProfileStore.saveMetadata(metadata)
  precondition(EnhancementProfileStore.metadata().hiddenPresets.isEmpty)
  precondition(EnhancementProfileStore.checkRename("Default",excluding:"preset:game") == .duplicate)
  try EnhancementProfileStore.renameNamed("游戏",to:"自定义新名")
  let renamed=EnhancementProfileStore.loadNamed("自定义新名")
  precondition(renamed?.configID=="custom:自定义新名" && renamed?.modelID=="rife-v4.26" && EnhancementProfileStore.loadNamed("游戏")==nil)
  precondition(EnhancementProfileStore.loadPreset("preset:game")==preset)
  var selected=renamed!;try EnhancementProfileStore.saveCurrent(selected)
  selected.outputWidth=1440;try EnhancementProfileStore.saveCurrent(selected)
  precondition(EnhancementProfileStore.load().configID=="custom:自定义新名" && EnhancementProfileStore.loadNamed("自定义新名")?.outputWidth==1440)
  // Same order as deletion: save a valid replacement first, then remove the
  // isolated fixture. Switching and editing must never recreate its old file.
  var replacement=preset;try EnhancementProfileStore.saveCurrent(replacement)
  try FileManager.default.removeItem(at:EnhancementProfileStore.namedDirectory().appendingPathComponent("自定义新名.json"))
  replacement.outputWidth=1600;try EnhancementProfileStore.saveCurrent(replacement)
  var next=EnhancementProfile();next.configID="preset:film";next.configName="电影"
  try EnhancementProfileStore.saveCurrent(next)
  next.outputHeight=900;try EnhancementProfileStore.saveCurrent(next)
  precondition(EnhancementProfileStore.load().configID=="preset:film" && EnhancementProfileStore.load().outputHeight==900)
  precondition(EnhancementProfileStore.loadNamed("自定义新名")==nil && EnhancementProfileStore.loadPreset("preset:game")?.outputWidth==1600)
  var gate=EnhancementCountdown();let first=gate.begin()!;precondition(gate.remaining==3 && gate.begin()==nil)
  precondition(gate.tick(first)==2);gate.cancel();precondition(gate.tick(first)==nil && !gate.active)
  let second=gate.begin()!;precondition(second != first && gate.tick(second)==2 && gate.tick(second)==1 && gate.tick(second)==0 && !gate.active)
  let suite="khua-config-contract-"+UUID().uuidString
  let defaults=UserDefaults(suiteName:suite)!
  defer { defaults.removePersistentDomain(forName:suite) }
  EnhancementText.setLanguage("zh",in:defaults);precondition(EnhancementText.language(in:defaults))
  EnhancementText.setLanguage("en",in:defaults);precondition(!EnhancementText.language(in:UserDefaults(suiteName:suite)!))
  FPSPreference.set(true,in:defaults);precondition(FPSPreference.enabled(in:UserDefaults(suiteName:suite)!))
  FPSPreference.set(false,in:defaults);precondition(!FPSPreference.enabled(in:defaults))
  precondition(FPSPresentation.rate(59.8,observing:true,now:10,receipt:9)==59.8)
  precondition(FPSPresentation.rate(59.8,observing:false,now:10,receipt:9)==nil)
  precondition(FPSPresentation.rate(59.8,observing:true,now:11,receipt:9)==nil)
  precondition(FPSPresentation.rate(.nan,observing:true,now:10,receipt:9)==nil)
  precondition(FPSPresentation.rate(59.8,observing:true,now:10,receipt:0)==nil)
  precondition(!TargetOverlayPolicy.shouldCancel(exists:true,onscreen:false,wasOnscreen:false))
  precondition(TargetOverlayPolicy.shouldCancel(exists:true,onscreen:false,wasOnscreen:true))
  precondition(TargetOverlayPolicy.shouldCancel(exists:false,onscreen:false,wasOnscreen:false))
  func cgWindow(_ id:Int,_ owner:Int,_ layer:Int,_ w:Double,_ h:Double,_ onscreen:Bool = true,_ alpha:Double = 1) -> [String:Any] {
   [kCGWindowNumber as String:id,kCGWindowOwnerPID as String:owner,kCGWindowLayer as String:layer,
    kCGWindowIsOnscreen as String:onscreen,kCGWindowAlpha as String:alpha,
    kCGWindowBounds as String:["X":10,"Y":20,"Width":w,"Height":h]]
  }
  let targetWindow=cgWindow(101,77,0,1200,800)
  let floatingAux=cgWindow(202,77,7,500,300), transparentAux=cgWindow(203,77,0,300,200,true,0)
  let otherBrowserWindow=cgWindow(102,77,0,1000,700,true,0.65)
  let anotherAppWindow=cgWindow(301,88,0,1000,700)
  func decision(_ windows:[[String:Any]],_ front:pid_t?=77)->TargetOverlayPolicy.WindowDecision {
   TargetOverlayPolicy.evaluateWindow(windows,orderedOnscreen:windows,id:101,owner:77,frontPID:front)
  }
  precondition(decision([floatingAux,transparentAux,targetWindow]).matches)
  let competing=decision([floatingAux,otherBrowserWindow,targetWindow])
  precondition(competing.reason=="other_window_frontmost" && competing.competing?.id==102 && competing.competing?.layer==0)
  precondition(decision([anotherAppWindow,targetWindow],88).reason=="other_app_frontmost")
  precondition(decision([cgWindow(101,77,0,1200,800,false)]).reason=="target_offscreen")
  precondition(decision([floatingAux]).reason=="target_missing")
  precondition(decision([floatingAux,cgWindow(101,77,4,1200,800),otherBrowserWindow]).matches)
  precondition(decision([targetWindow],nil).reason=="front_process_unknown")
  precondition(decision([cgWindow(101,88,0,1200,800)]).reason=="target_owner_changed")
  var missingMetadata=targetWindow; missingMetadata.removeValue(forKey:kCGWindowLayer as String)
  precondition(decision([missingMetadata]).reason=="target_metadata_incomplete")
  let allUnordered=[targetWindow,otherBrowserWindow,floatingAux]
  let orderedBehind=TargetOverlayPolicy.evaluateWindow(allUnordered,orderedOnscreen:[floatingAux,otherBrowserWindow,targetWindow],id:101,owner:77,frontPID:77)
  let orderedFront=TargetOverlayPolicy.evaluateWindow([otherBrowserWindow,targetWindow],orderedOnscreen:[targetWindow,otherBrowserWindow],id:101,owner:77,frontPID:77)
  precondition(orderedBehind.reason=="other_window_frontmost" && orderedBehind.competing?.id==102 && orderedFront.matches)
  precondition(TargetOverlayPolicy.evaluateWindow([targetWindow],orderedOnscreen:nil,id:101,owner:77,frontPID:77).reason=="onscreen_window_list_unavailable")
  precondition(TargetOverlayPolicy.evaluateWindow([targetWindow],orderedOnscreen:[otherBrowserWindow],id:101,owner:77,frontPID:77).reason=="target_not_in_ordered_list")
  precondition(TargetOverlayPolicy.evaluateWindow([targetWindow],orderedOnscreen:[cgWindow(101,88,0,1200,800)],id:101,owner:77,frontPID:77).reason=="target_identity_changed_in_ordered_list")
  precondition(decision([cgWindow(101,77,0,1200,800,true,0)]).reason=="target_transparent")
  func reveals(_ t:UInt64,_ g:UInt64,_ c:UInt64,_ visible:Bool)->Bool {
   TargetOverlayPolicy.canReveal(token:t,currentToken:3,generation:g,currentGeneration:4,config:c,currentConfig:5,targetReady:visible)
  }
  precondition(reveals(3,4,5,true) && !reveals(2,4,5,true) && !reveals(3,3,5,true) && !reveals(3,4,4,true) && !reveals(3,4,5,false))
  let screen=NSRect(x:-1440,y:180,width:1440,height:900)
  let display=CGRect(x:-2880,y:-360,width:2880,height:1800)
  let target=CGRect(x:-2680,y:-160,width:800,height:400)
  precondition(TargetOverlayPolicy.nativeFrame(target,cgDisplay:display,screen:screen)==NSRect(x:-1340,y:780,width:400,height:200))
  let primary=NSRect(x:0,y:0,width:1920,height:1080), targetFrame=NSRect(x:50,y:60,width:800,height:600)
  precondition(TargetOverlayPolicy.outputFrame(target:targetFrame,fullscreen:false,display:primary)==targetFrame)
  precondition(TargetOverlayPolicy.outputFrame(target:targetFrame,fullscreen:true,display:primary)==primary)
  precondition(TargetOverlayPolicy.outputFrame(target:targetFrame,fullscreen:true,display:nil)==nil)
  precondition(VideoSRAvailability.readyFactors(isFile:false,inputReady:true,factors:[2]) == [])
  let ll=LiveEngineSelection.fromPopup(1,quality:"fast"), rife=LiveEngineSelection.fromPopup(3,quality:"fast")
  precondition(LiveCoverage.modelScheduled(total:100,held:100)==0 && LiveCoverage.modelScheduled(total:100,held:40)==60 && LiveCoverage.modelScheduled(total:0,held:1)==0)
  precondition(ll.engine=="apple.lowlatency" && ll.model=="vt.llfi.temporal" && rife.engine=="rife.metal" && rife.model=="rife-v4.26")
  var tracker=LiveApplyTracker(); let firstRequest=tracker.begin(); let secondRequest=tracker.begin()
  precondition(!tracker.resolve(firstRequest,state:2) && tracker.pending==secondRequest)
  precondition(tracker.resolve(secondRequest,state:1) && tracker.pending==secondRequest)
  precondition(!tracker.resolve(firstRequest,state:0) && tracker.pending==secondRequest)
  precondition(tracker.resolve(secondRequest,state:0) && tracker.pending==nil)
  let third=tracker.begin(); tracker.cancel(); precondition(!tracker.resolve(third,state:2))
  precondition(VideoSRAvailability.readyFactors(isFile:false,inputReady:true,factors:[2,4]) == [4])
  precondition(VideoSRAvailability.readyFactors(isFile:true,inputReady:true,factors:[4,2]) == [2,4])
  precondition(VideoSRAvailability.readyFactors(isFile:true,inputReady:false,factors:[4]) == [])
  var videoSR=EnhancementProfile();videoSR.sourceKind="file";videoSR.scaleEnabled=true;videoSR.scaleEngineID="apple.video-sr";videoSR.outputWidth=1920;videoSR.outputHeight=1080;videoSR.interpolationEnabled=true;videoSR.interpolationEngineID="rife.metal";videoSR.modelID="rife-v4.26";videoSR.rate = .multiplier(2)
  try EnhancementProfileStore.save(videoSR);precondition(EnhancementProfileStore.load()==videoSR)
  _ = EnhancementText.t("Technology Library","技术库")
  precondition(EnhancementText.translated("技术库",chinese:false)=="Technology Library")
  precondition(EnhancementText.translated("用户来源",chinese:false)=="用户来源")
  print("{\"ok\":true,\"legacyCollisionPreserved\":true,\"presetSeparate\":true,\"editReadback\":true,\"renameAndRestoreMetadata\":true,\"countdownCancelAndIdempotence\":true,\"fpsPreference\":true,\"browserMetadataSelection\":true,\"onscreenOrderUsed\":true,\"competingNormalWindowHidden\":true,\"auxiliaryAndNonzeroTarget\":true,\"offscreenAndOtherOwner\":true,\"nameValidation\":true,\"isolatedLanguagePreferences\":true,\"fileVideoSRCombinationReadback\":true,\"videoSRLiveFactorBoundary\":true,\"scope\":\"isolated store/timer/CG metadata/preferences contract; no GUI or live user config\"}")
 }
}
