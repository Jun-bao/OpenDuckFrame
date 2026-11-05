enum AppLanguage { static var current: String? { nil }; static func effectiveLanguage(for code: String?) -> String? { "en" } }

// Execute the production handler's size-selection section with control values,
// without opening windows or writing a live profile.
private struct SizePopup {
 var indexOfSelectedItem: Int
 mutating func selectItem(at index: Int) { indexOfSelectedItem = index }
}
private final class SourceSizeControls {
 var scalePopup = SizePopup(indexOfSelectedItem: 1)
 var sourceWindowPopup = SizePopup(indexOfSelectedItem: 2)
 var windowOutputPopup = SizePopup(indexOfSelectedItem: 0)
 var sourceKindControl = (selectedSegment: 0, unused: 0)
 var scaleSwitch = (state: NSControl.StateValue.on, unused: 0)
 var profile = EnhancementProfile()
 var outputSize: (Int, Int)?
 func selectOutputSize(_ width: Int, _ height: Int) { outputSize = (width,height) }
 func changeSourceSize() {
  // ACTUAL_SOURCE_WINDOW_CONTROL_CHANGE
 }
}


@main struct TestRunner {
 @MainActor static func main() throws {
  for mode in 0...3 {
   let controls = SourceSizeControls()
   controls.profile.sourceWindowPreset = 480
   controls.windowOutputPopup.selectItem(at: mode)
   controls.changeSourceSize()
   precondition(controls.windowOutputPopup.indexOfSelectedItem == mode,
     "Changing source size must preserve the user's output/input mode")
   precondition(controls.outputSize?.0 == 2560 && controls.outputSize?.1 == 1440)
  }
  for source in 0...2 {
   let controls = SourceSizeControls()
   controls.sourceKindControl.selectedSegment = source
   controls.scaleSwitch.state = .off
   controls.changeSourceSize()
   precondition(controls.windowOutputPopup.indexOfSelectedItem == 0 && controls.outputSize == nil)
  }
  let p0Args = ["--odf-p0-controls", "--odf-r7-opaque"]
  precondition(P0DiagnosticPolicy.controlsEnabled(args:p0Args,isolated:true))
  precondition(!P0DiagnosticPolicy.controlsEnabled(args:p0Args,isolated:false))
  precondition(P0DiagnosticPolicy.flag("--odf-r7-opaque",args:p0Args,isolated:true,overrideValue:nil))
  precondition(!P0DiagnosticPolicy.flag("--odf-r7-opaque",args:p0Args,isolated:true,overrideValue:false))
  precondition(P0DiagnosticPolicy.flag("--odf-r7-activate",args:p0Args,isolated:true,overrideValue:true))
  precondition(!P0DiagnosticPolicy.flag("--odf-r7-activate",args:p0Args,isolated:false,overrideValue:true))
  precondition(!P0DiagnosticPolicy.flag("--odf-r7-activate",args:[],isolated:true,overrideValue:true))
  precondition(WorkbenchTitle.text("Quality Workbench",version:" 0.1.0 ") == "Quality Workbench · v0.1.0")
  precondition(WorkbenchTitle.text("画质工作台",version:"0.1.0") == "画质工作台 · v0.1.0")
  precondition(WorkbenchTitle.text("画质工作台",version:"1.2.3") == "画质工作台 · v1.2.3")
  precondition(WorkbenchTitle.text("画质工作台",version:"") == "画质工作台")
  precondition(WorkbenchTitle.text("Quality Workbench",version:" \n ") == "Quality Workbench")
  precondition(WorkbenchTitle.text("画质工作台",version:nil) == "画质工作台")
  var oldProfile = try JSONSerialization.jsonObject(with: JSONEncoder().encode(EnhancementProfile())) as! [String: Any]
  oldProfile.removeValue(forKey:"windowOutputMode")
  let oldData = try JSONSerialization.data(withJSONObject:oldProfile)
  precondition(EnhancementProfileStore.decode(oldData,fallbackName:"legacy")?.windowOutputMode == "follow")
  oldProfile["sourceKind"] = "display"; oldProfile["outputFullscreen"] = true
  let displayOld = EnhancementProfileStore.decode(try JSONSerialization.data(withJSONObject:oldProfile),fallbackName:"legacy")!
  precondition(displayOld.windowOutputMode == "follow" && displayOld.outputFullscreen &&
    TargetOverlayPolicy.usesFullscreen(windowTarget:false,explicitViewer:false,interactiveAvailable:false,diagnosticFullscreen:false,legacyFullscreen:displayOld.outputFullscreen,viewerFollowOverride:false))
  oldProfile["sourceKind"] = "window"
  let windowOld = EnhancementProfileStore.decode(try JSONSerialization.data(withJSONObject:oldProfile),fallbackName:"legacy")!
  precondition(windowOld.windowOutputMode == "follow" && !TargetOverlayPolicy.usesFullscreen(windowTarget:true,explicitViewer:false,interactiveAvailable:false,diagnosticFullscreen:false,legacyFullscreen:windowOld.outputFullscreen,viewerFollowOverride:false))
  oldProfile["sourceKind"] = "file"
  let fileOld = EnhancementProfileStore.decode(try JSONSerialization.data(withJSONObject:oldProfile),fallbackName:"legacy")!
  precondition(fileOld.sourceKind == "file" && fileOld.outputFullscreen)
  oldProfile["windowOutputMode"] = "unknown"
  let unknownData = try JSONSerialization.data(withJSONObject:oldProfile)
  precondition(EnhancementProfileStore.decode(unknownData,fallbackName:"legacy")?.windowOutputMode == "follow")
  for preset in [480, 720] {
   for interpolation in [false, true] {
    for scale in [false, true] {
     var combination = EnhancementProfile()
     combination.sourceWindowPreset = preset
     combination.interpolationEnabled = interpolation
     combination.scaleEnabled = scale
     precondition(combination.sourceWindowResizeActive == scale)
     let saved = try JSONEncoder().encode(combination)
     let restored = EnhancementProfileStore.decode(saved, fallbackName:"test")!
     precondition(restored.sourceWindowPreset == preset && restored.interpolationEnabled == interpolation && restored.sourceWindowResizeActive == scale)
     var resumed = restored; resumed.scaleEnabled = true
     precondition(resumed.sourceWindowResizeActive && resumed.sourceWindowPreset == preset)
     resumed.sourceKind = "display"; precondition(!resumed.sourceWindowResizeActive)
     resumed.sourceKind = "file"; precondition(!resumed.sourceWindowResizeActive)
     resumed.sourceKind = "window"; resumed.sourceWindowPreset = 0; precondition(!resumed.sourceWindowResizeActive)
    }
   }
  }
  oldProfile["windowOutputMode"] = "absolute"
  let absoluteData = try JSONSerialization.data(withJSONObject:oldProfile)
  precondition(EnhancementProfileStore.decode(absoluteData,fallbackName:"legacy")?.windowOutputMode == "absolute")
  precondition(WorkbenchDimensionPolicy.editable(sizeIndex: 4, scaleEnabled: true))
  for index in [0, 1, 2, 3, 5] { precondition(!WorkbenchDimensionPolicy.editable(sizeIndex: index, scaleEnabled: true)) }
  precondition(!WorkbenchDimensionPolicy.editable(sizeIndex: 4, scaleEnabled: false))
  precondition(WorkbenchDimensionPolicy.value("1920") == 1920 && WorkbenchDimensionPolicy.value(" 1081 ") == 1080)
  for invalid in ["", "—", "abc", "-2", "1", "99999999999999999999999999", "3.5"] { precondition(WorkbenchDimensionPolicy.value(invalid) == nil) }
  precondition(WorkbenchDimensionPolicy.text(0) == "—" && WorkbenchDimensionPolicy.text(1920) == "1920")
  let temp=FileManager.default.temporaryDirectory.appendingPathComponent("odf-config-contract-"+UUID().uuidString)
  try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
  defer { try? FileManager.default.removeItem(at:temp) }
  EnhancementProfileStore.testDirectory=temp
  func hasDefaultEnhancement(_ p: EnhancementProfile) -> Bool {
   p.interpolationEnabled && p.interpolationEngineID == "rife.metal" && p.modelID == "rife-v4.25" &&
    p.interpolationQuality == "fast" && p.rifeStreamEnabled && p.rate == .multiplier(2) &&
    !p.scaleEnabled && p.windowOutputMode == "follow"
  }
  precondition(hasDefaultEnhancement(EnhancementProfileStore.load()))
  try Data("invalid".utf8).write(to: EnhancementProfileStore.fileURL())
  precondition(hasDefaultEnhancement(EnhancementProfileStore.load()))
  var defaultPreset = EnhancementProfile(); defaultPreset.interpolationEnabled = false
  defaultPreset.interpolationEngineID = "apple.frc"; defaultPreset.interpolationQuality = "quality"
  defaultPreset.modelID = "vt.frc.quality"; defaultPreset.rifeStreamEnabled = false
  defaultPreset.rate = .multiplier(3); defaultPreset.scaleEnabled = true; defaultPreset.windowOutputMode = "viewer"
  applyDefaultPreset(&defaultPreset)
  precondition(hasDefaultEnhancement(defaultPreset))
  for mode in ["viewer", "absolute", "relative"] {
   var savedDefault = EnhancementProfile()
   savedDefault.configID = "preset:default"; savedDefault.windowOutputMode = mode
   savedDefault.sourceWindowPreset = 720; savedDefault.scaleEnabled = true
   try EnhancementProfileStore.saveCurrent(savedDefault)
   var expected = savedDefault; expected.windowOutputMode = "follow"
   precondition(EnhancementProfileStore.load() == expected)
   precondition(EnhancementProfileStore.loadPreset("preset:default") == expected)
   var customViewer = savedDefault
   customViewer.configName = "explicit-viewer"; customViewer.configID = "custom:explicit-viewer"
   try EnhancementProfileStore.saveCurrent(customViewer)
   precondition(EnhancementProfileStore.load() == customViewer)
   precondition(EnhancementProfileStore.loadNamed("explicit-viewer") == customViewer)
  }
  var userOverride = EnhancementProfile(); userOverride.interpolationEnabled = false; userOverride.rifeStreamEnabled = false
  try EnhancementProfileStore.save(userOverride)
  precondition(EnhancementProfileStore.load() == userOverride)
  var copiedConfig = EnhancementProfileStore.load(); copiedConfig.configName = "复制设置"; copiedConfig.configID = "custom:复制设置"
  try EnhancementProfileStore.saveNamed(copiedConfig)
  precondition(EnhancementProfileStore.loadNamed("复制设置") == copiedConfig && !copiedConfig.rifeStreamEnabled)
  var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(userOverride)) as! [String: Any]
  legacy.removeValue(forKey: "rifeStreamEnabled")
  let decodedLegacy = EnhancementProfileStore.decode(try JSONSerialization.data(withJSONObject: legacy), fallbackName: "legacy")!
  precondition(!decodedLegacy.rifeStreamEnabled && !decodedLegacy.interpolationEnabled)
  var native=EnhancementProfile(); native.interpolationEngineID="apple.lowlatency"; native.scaleEnabled=true; native.outputWidth=1920; native.outputHeight=1080
  applyNativeQualityPreset(&native)
  precondition(native.interpolationEnabled && native.interpolationEngineID == "apple.frc" && native.modelID == "vt.frc.quality" && native.interpolationQuality == "quality" && native.rate == .multiplier(2) && !native.scaleEnabled && native.outputWidth == 0 && native.outputHeight == 0)
  precondition(EnhancementProfileStore.presets.contains { $0.id == "preset:native" })
  let sizeStats: [String: Any] = ["sizeChain": ["sourceGeneration": UInt64(4), "configVersion": UInt64(7), "endpoint": "output", "sourceWidth": 2560, "sourceHeight": 1440, "processingWidth": 1920, "processingHeight": 1080, "bufferWidth": 1920, "bufferHeight": 1080, "drawableWidth": 2560, "drawableHeight": 1440, "downsampled": true]]
  let sizeText=LiveSizeChain.text(sizeStats,generation:4,config:7)
  precondition(sizeText.contains("2560×1440") && sizeText.contains("1920×1080") && sizeText.contains("Drawable") && sizeText.contains("Downsampled"))
  precondition(LiveSizeChain.text(sizeStats,generation:4,config:8).isEmpty && LiveSizeChain.text(sizeStats,generation:5,config:7).isEmpty)
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
  let delayed=gate.begin(seconds:5)!;precondition(gate.remaining==5 && gate.tick(first)==nil)
  for remaining in (0...4).reversed() { precondition(gate.tick(delayed)==remaining) }
  precondition(!gate.active && gate.tick(delayed)==nil)
  let suite="odf-config-contract-"+UUID().uuidString
  let defaults=UserDefaults(suiteName:suite)!
  defer { defaults.removePersistentDomain(forName:suite) }
  precondition(EnhancementDelayPreference.seconds(in:defaults)==5)
  EnhancementDelayPreference.set(20,in:defaults)
  precondition(EnhancementDelayPreference.seconds(in:UserDefaults(suiteName:suite)!)==20)
  EnhancementDelayPreference.set(99,in:defaults);precondition(EnhancementDelayPreference.seconds(in:defaults)==20)
  EnhancementDelayPreference.set(0,in:defaults);precondition(EnhancementDelayPreference.seconds(in:defaults)==1)
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
  // Choose the active app's foremost normal window, even if a previous source
  // or a nonactivating countdown panel is ahead of it in the global list.
  let countdownPanel=cgWindow(900,99,1000,2560,1440)
  let transient=cgWindow(901,77,0,66,20)
  precondition(TargetOverlayPolicy.focusedWindow([transient,otherBrowserWindow,targetWindow],frontPID:77,ownPID:99,focusedBounds:CGRect(x:10,y:20,width:1200,height:800))?.id==101)
  precondition(TargetOverlayPolicy.focusedWindow([countdownPanel,floatingAux,transparentAux,otherBrowserWindow,targetWindow],frontPID:77,ownPID:99)?.id==102)
  precondition(TargetOverlayPolicy.focusedWindow([targetWindow,anotherAppWindow],frontPID:88,ownPID:99)?.id==301)
  precondition(TargetOverlayPolicy.focusedWindow([targetWindow],frontPID:99,ownPID:99)==nil)
  precondition(TargetOverlayPolicy.focusedWindow([targetWindow],frontPID:nil,ownPID:99)==nil)
  precondition(TargetOverlayPolicy.focusedWindow([targetWindow],frontPID:88,ownPID:99)==nil)
  precondition(TargetOverlayPolicy.focusedWindow([cgWindow(101,77,0,1200,800,false)],frontPID:77,ownPID:99)==nil)
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
  // Fullscreen source bars and real competitors in actual front-to-back order.
  func positioned(_ id:Int, _ x:Double, _ y:Double, _ w:Double, _ h:Double) -> [String:Any] {
   var window=cgWindow(id,77,0,w,h); window[kCGWindowBounds as String] = ["X":x,"Y":y,"Width":w,"Height":h]
   window[kCGWindowName as String] = "window-\(id)"; return window
  }
  let full=positioned(101,0,0,2560,1440)
  let upper=positioned(41844,0,-81,2560,81), toolbar=positioned(47424,0,0,2560,115)
  precondition(decision([upper,full]).matches)
  precondition(decision([toolbar,full]).matches)
  let bothBars=decision([upper,toolbar,full])
  precondition(bothBars.matches && bothBars.ignored.map(\.id)==[41844,47424] && bothBars.ignored.map(\.name)==["window-41844","window-47424"])
  precondition(decision([upper,toolbar]).ignored.isEmpty)
  precondition(decision([positioned(41844,1884,-81,2560,81),positioned(101,1884,0,2560,1440)]).matches)
  let beneath=decision([upper,positioned(500,20,100,600,400),full])
  precondition(beneath.reason=="other_window_frontmost" && beneath.competing?.id==500)
  for item in [positioned(501,0,0,600,400),positioned(502,0,0,2560,375),positioned(503,0,0,1200,100),
               positioned(504,0,1340,2560,100),positioned(505,20,0,2560,100)] {
   precondition(decision([item,full]).reason=="other_window_frontmost")
  }
  // Preparation, failure/revoke, and geometry-loss never click through.
  precondition(!TargetOverlayPolicy.interactionCanPassThrough(available:true,routerActive:false))
  precondition(TargetOverlayPolicy.interactionCanPassThrough(available:true,routerActive:true))
  precondition(!TargetOverlayPolicy.interactionCanPassThrough(available:false,routerActive:false))
  let owned=TargetOverlayPolicy.interactionOwnedPassThrough(output:202,controls:203,huds:[204])
  precondition(owned == Set([202,203,204]) && !owned.contains(301)) // ordinary workbench/other windows remain competitors
  precondition(P1AXInvestigation.rectMatches(CGRect(x:10,y:20,width:640,height:512),CGRect(x:11,y:20,width:640,height:512)))
  precondition(!P1AXInvestigation.rectMatches(CGRect(x:10,y:20,width:640,height:512),CGRect(x:14,y:20,width:640,height:512)))
  precondition(P1AXInvestigation.uniqueGeometry(total:2,readable:2,matches:1,listSucceeded:true))
  precondition(!P1AXInvestigation.uniqueGeometry(total:2,readable:1,matches:1,listSucceeded:true))
  precondition(!P1AXInvestigation.uniqueGeometry(total:2,readable:2,matches:2,listSucceeded:true))
  precondition(!P1AXInvestigation.uniqueGeometry(total:9,readable:9,matches:1,listSucceeded:true))
  precondition(!P1AXInvestigation.uniqueGeometry(total:1,readable:1,matches:1,listSucceeded:false))
  precondition(P1FocusPolicy.decide(targetReady:false,acquired:false,ownFront:true,now:2,deadline:5) == .wait)
  precondition(P1FocusPolicy.decide(targetReady:false,acquired:false,ownFront:true,now:5,deadline:5) == .cancel)
  precondition(P1FocusPolicy.decide(targetReady:false,acquired:false,ownFront:false,now:2,deadline:5) == .cancel)
  precondition(P1FocusPolicy.decide(targetReady:true,acquired:false,ownFront:false,now:2,deadline:5) == .ready)
  precondition(P1FocusPolicy.decide(targetReady:false,acquired:true,ownFront:true,now:2,deadline:5) == .cancel)
  var wait=P1ObstructionWait()
  precondition(wait.observe(blocked:true,now:100,generation:1,config:2))
  precondition(wait.observe(blocked:true,now:104.9,generation:1,config:2))
  precondition(wait.observe(blocked:false,now:104.95,generation:1,config:2))
  precondition(wait.observe(blocked:true,now:105,generation:1,config:2))
  precondition(!wait.observe(blocked:true,now:110,generation:1,config:2))
  wait.reset(); precondition(wait.observe(blocked:true,now:111,generation:1,config:2))
  precondition(!wait.observe(blocked:false,now:116,generation:1,config:2)) // clear after deadline cannot revive
  wait.reset(); precondition(wait.observe(blocked:true,now:120,generation:1,config:2))
  precondition(!wait.observe(blocked:true,now:121,generation:2,config:2))
  precondition(wait.observe(blocked:true,now:130,generation:1,config:2))
  precondition(!wait.observe(blocked:true,now:131,generation:1,config:3))
  wait.reset(); precondition(!wait.observe(blocked:true,now:0,generation:0,config:2))
  let sourceRect=CGRect(x:10,y:20,width:640,height:480)
  func clear(_ windows:[[String:Any]]?,_ passthrough:Set<CGWindowID> = []) -> Bool {
   TargetOverlayPolicy.interactionUnobstructed(windows,id:101,owner:77,source:sourceRect,passthrough:passthrough)
  }
  let smallPopup=cgWindow(207,77,8,20,20)
  precondition(clear([targetWindow]))
  precondition(!clear([smallPopup,targetWindow]))
  precondition(!clear([anotherAppWindow,targetWindow]))
  precondition(clear([floatingAux,targetWindow],[202]))
  precondition(!clear([transparentAux,targetWindow])) // alpha alone does not establish hit-test pass-through
  precondition(!clear([cgWindow(209,88,9,20,20,true,0.005),targetWindow]))
  precondition(!clear(nil) && !clear([smallPopup]) && !clear([missingMetadata,targetWindow]))
  var noAlpha=smallPopup; noAlpha.removeValue(forKey:kCGWindowAlpha as String)
  precondition(!clear([noAlpha,targetWindow]))
  // A real prior-policy counterexample: valid disjoint bounds with missing
  // metadata failed normalizeWindow, but cannot intercept any source point.
  let farPartial: [String:Any] = [kCGWindowNumber as String: 901,
      kCGWindowBounds as String: ["X": 4000, "Y": 4000, "Width": 0.5, "Height": 0.5]]
  precondition(TargetOverlayPolicy.normalizeWindow(farPartial) == nil && clear([farPartial,targetWindow]))
  var farMissingID=farPartial; farMissingID.removeValue(forKey:kCGWindowNumber as String)
  precondition(clear([farMissingID,targetWindow]))
  let tinyOverlap=cgWindow(208,77,9,0.5,0.5)
  let tinyResult=TargetOverlayPolicy.interactionGuard([tinyOverlap,targetWindow],id:101,owner:77,source:sourceRect,passthrough:[])
  precondition(!tinyResult.clear && tinyResult.reason == "overlapping_window" && (tinyResult.blocker["windowID"] as? CGWindowID) == 208)
  var unknownBounds=smallPopup; unknownBounds.removeValue(forKey:kCGWindowBounds as String)
  let unknownResult=TargetOverlayPolicy.interactionGuard([unknownBounds,targetWindow],id:101,owner:77,source:sourceRect,passthrough:[])
  precondition(!unknownResult.clear && unknownResult.missing.contains("bounds") && unknownResult.targetFound == "yes")
  let missingAlphaResult=TargetOverlayPolicy.interactionGuard([noAlpha,targetWindow],id:101,owner:77,source:sourceRect,passthrough:[])
  precondition(!missingAlphaResult.clear && missingAlphaResult.missing.contains("alpha"))
  var noTargetAlpha=targetWindow; noTargetAlpha.removeValue(forKey:kCGWindowAlpha as String)
  precondition(!clear([noTargetAlpha]) && !clear([cgWindow(101,88,0,1200,800)]))
  var workbench=anotherAppWindow; workbench[kCGWindowName as String]="private title"
  let workbenchResult=TargetOverlayPolicy.interactionGuard([workbench,targetWindow],id:101,owner:77,source:sourceRect,passthrough:owned)
  precondition(!workbenchResult.clear && workbenchResult.reason == "overlapping_window" && workbenchResult.blocker["title"] == nil && workbenchResult.blocker[kCGWindowName as String] == nil)
  precondition(clear([floatingAux,targetWindow],[202]))
  func reveals(_ t:UInt64,_ g:UInt64,_ c:UInt64,_ visible:Bool)->Bool {
   TargetOverlayPolicy.canReveal(token:t,currentToken:3,generation:g,currentGeneration:4,config:c,currentConfig:5,targetReady:visible)
  }
  precondition(reveals(3,4,5,true) && !reveals(2,4,5,true) && !reveals(3,3,5,true) && !reveals(3,4,4,true) && !reveals(3,4,5,false))
  let screen=NSRect(x:-1440,y:180,width:1440,height:900)
  let display=CGRect(x:-2880,y:-360,width:2880,height:1800)
  let target=CGRect(x:-2680,y:-160,width:800,height:400)
  precondition(TargetOverlayPolicy.nativeFrame(target,cgDisplay:display,screen:screen)==NSRect(x:-1340,y:780,width:400,height:200))
  let primary=NSRect(x:0,y:0,width:1920,height:1080), targetFrame=NSRect(x:50,y:60,width:800,height:600)
  // A stalled old generation/config must never spend a new one's single retry.
  var health = R7PresentationHealth()
  func sample(_ gen: UInt64, _ config: UInt64, _ accepted: UInt64, _ presented: UInt64, _ changing: Bool = true, _ running: Bool = true) -> (Bool, Bool) {
   let result = health.observe(generation: gen, config: config, running: running, visible: true, accepted: accepted, presented: presented, changingContent: changing)
   return (result.firstStall, result.rearm)
  }
  precondition(!sample(1,1,10,2).1)
  precondition(!sample(1,1,11,2).1 && !sample(1,1,12,2).1)
  let firstStall = sample(1,1,13,2); precondition(firstStall.0 && firstStall.1)
  precondition(!sample(1,1,14,2).1)
  precondition(!sample(2,1,1,0).1 && health.stallSeconds == 0 && !health.recoveryAttempted)
  precondition(!sample(2,1,2,0).1 && !sample(2,1,3,0).1 && sample(2,1,4,0).1)
  precondition(!sample(2,2,5,0).1 && health.stallSeconds == 0 && !health.recoveryAttempted)
  precondition(!sample(2,2,6,0,false).1 && !sample(2,2,7,0,false).1 && !sample(2,2,8,0,false).1)
  precondition(sample(2,2,9,0,true).1)
  precondition(!sample(2,2,9,0,true,false).1 && !health.recoveryAttempted && health.stallSeconds == 0)
  precondition(!sample(2,2,10,0).1 && !sample(2,2,11,0).1 && !sample(2,2,12,0).1 && sample(2,2,13,0).1)
  precondition(!sample(2,2,14,1).1 && !health.recoveryAttempted)
  precondition(!sample(2,2,1,0).1 && health.stallSeconds == 0)
  func freshChange(_ now: UInt64, _ host: UInt64, _ gen: UInt64 = 7, _ cfg: UInt64 = 8, _ epoch: UInt64 = 9, _ stale: Bool = false) -> Bool {
   R7ContentChangeEvidence.isFresh(now: now, host: host, numer: 1, denom: 1, generation: 7, config: 8, epoch: 9,
     evidenceGeneration: gen, evidenceConfig: cfg, evidenceEpoch: epoch, snapshotStale: stale)
  }
  precondition(freshChange(2_000_000_000, 1_000_000_000))
  precondition(!freshChange(3_000_000_001, 1_000_000_000) && !freshChange(2_000_000_000, 0))
  precondition(!freshChange(2_000_000_000, 1_000_000_000, 6) && !freshChange(2_000_000_000, 1_000_000_000, 7, 7))
  precondition(!freshChange(2_000_000_000, 1_000_000_000, 7, 8, 8) && !freshChange(2_000_000_000, 1_000_000_000, 7, 8, 9, true))
  precondition(!freshChange(999_999_999, 1_000_000_000))
  var staticAfterMotion = R7PresentationHealth()
  for tick in 0...7 {
   let now = UInt64(2 + tick) * 1_000_000_000
   let result = staticAfterMotion.observe(generation: 7, config: 8, running: true, visible: true,
       accepted: UInt64(100 + tick), presented: 3, changingContent: freshChange(now, 1_000_000_000))
   precondition(!result.rearm) // Accepted frames keep advancing long after the last actual sampled change.
  }
  precondition(staticAfterMotion.stallSeconds >= 3 && !staticAfterMotion.recoveryAttempted)
  let freshMotion = staticAfterMotion.observe(generation: 7, config: 8, running: true, visible: true,
      accepted: 108, presented: 3, changingContent: freshChange(10_000_000_000, 9_800_000_000))
  precondition(freshMotion.rearm)
  let footer = FooterMetrics.lines(target:"目标 ≈120",output:"输出 59.5 FPS",generation:"生成 1.0/秒 · 按期合成 0.0/秒",
    budget:"插帧预算不足（需要 124 ms，可用 71 ms）",stalled:"",overdue:"",supplemental:["合成 1/100", "显示器上限"])
  precondition(footer.primary == "目标 ≈120 · 输出 59.5 FPS · 生成 1.0/秒 · 按期合成 0.0/秒")
  precondition(footer.secondary.hasPrefix("插帧预算不足（需要 124 ms，可用 71 ms）") && footer.secondary.contains("合成 1/100"))
  let englishFooter = FooterMetrics.lines(target:"Target ≈120",output:"Output 59.5 FPS",generation:"Generated 1.0/s · on-time 0.0/s",
    budget:"FRC budget limited (needs 124 ms, allows 71 ms)",stalled:"",overdue:"",supplemental:[])
  precondition(englishFooter.primary.contains("Target ≈120") && englishFooter.primary.contains("Output 59.5 FPS") && englishFooter.primary.contains("on-time 0.0/s"))
  precondition(englishFooter.secondary == "FRC budget limited (needs 124 ms, allows 71 ms)")
  precondition(FooterMetrics.lines(target:"",output:"",generation:"",budget:"",stalled:"",overdue:"",supplemental:[]).primary.isEmpty)
  precondition(TargetOverlayPolicy.windowInputAligned(viewMode:"enhanced"))
  precondition(TargetOverlayPolicy.windowInputAligned(viewMode:"original"))
  precondition(!TargetOverlayPolicy.windowInputAligned(viewMode:"compare"))
  precondition(TargetOverlayPolicy.outputFrame(target:targetFrame,fullscreen:false,display:primary)==targetFrame)
  precondition(TargetOverlayPolicy.outputFrame(target:targetFrame,fullscreen:true,display:primary)==primary)
  precondition(TargetOverlayPolicy.outputFrame(target:targetFrame,fullscreen:true,display:nil)==nil)
  precondition(TargetOverlayPolicy.followsTarget(fullscreen:false,viewerFollowOverride:false))
  precondition(!TargetOverlayPolicy.followsTarget(fullscreen:true,viewerFollowOverride:false))
  precondition(TargetOverlayPolicy.followsTarget(fullscreen:true,viewerFollowOverride:true))
  let savedViewer = "viewer"
  var followOverride = true // Esc changes only session state, not the saved preference.
  precondition(!TargetOverlayPolicy.activeWindowViewer(windowTarget:true,viewerSelected:savedViewer == "viewer",viewerFollowOverride:followOverride))
  precondition(!TargetOverlayPolicy.usesFullscreen(windowTarget:true,explicitViewer:true,interactiveAvailable:false,diagnosticFullscreen:false,legacyFullscreen:false,viewerFollowOverride:followOverride))
  followOverride = false // A successful new apply clears the override.
  precondition(savedViewer == "viewer" && TargetOverlayPolicy.activeWindowViewer(windowTarget:true,viewerSelected:savedViewer == "viewer",viewerFollowOverride:followOverride))
  precondition(TargetOverlayPolicy.usesFullscreen(windowTarget:true,explicitViewer:true,interactiveAvailable:false,diagnosticFullscreen:false,legacyFullscreen:false,viewerFollowOverride:followOverride))
  precondition(TargetOverlayPolicy.usesFullscreen(windowTarget:true,explicitViewer:false,interactiveAvailable:true,diagnosticFullscreen:false,legacyFullscreen:false,viewerFollowOverride:true))
  precondition(TargetOverlayPolicy.usesFullscreen(windowTarget:true,explicitViewer:true,interactiveAvailable:false,diagnosticFullscreen:true,legacyFullscreen:false,viewerFollowOverride:true))
  let cadenceScreens = [NSRect(x:0,y:0,width:1000,height:800), NSRect(x:1000,y:0,width:1000,height:800)]
  precondition(TargetOverlayPolicy.screenIndex(target:NSRect(x:700,y:50,width:400,height:300),screens:cadenceScreens)==0)
  precondition(TargetOverlayPolicy.screenIndex(target:NSRect(x:900,y:50,width:400,height:300),screens:cadenceScreens)==1)
  precondition(TargetOverlayPolicy.screenIndex(target:NSRect(x:2100,y:50,width:100,height:100),screens:cadenceScreens)==nil)
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
  print("{\"ok\":true,\"legacyCollisionPreserved\":true,\"presetSeparate\":true,\"editReadback\":true,\"renameAndRestoreMetadata\":true,\"countdownCancelAndIdempotence\":true,\"fpsPreference\":true,\"browserMetadataSelection\":true,\"onscreenOrderUsed\":true,\"competingNormalWindowHidden\":true,\"auxiliaryAndNonzeroTarget\":true,\"offscreenAndOtherOwner\":true,\"nameValidation\":true,\"isolatedLanguagePreferences\":true,\"fileVideoSRCombinationReadback\":true,\"videoSRLiveFactorBoundary\":true,\"r7RecoveryLifecycle\":true,\"scope\":\"isolated store/timer/CG metadata/preferences contract; no GUI or live user config\"}")
 }
}
