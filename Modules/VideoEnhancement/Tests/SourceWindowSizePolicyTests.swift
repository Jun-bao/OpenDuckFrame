import Foundation
import CoreGraphics

@main struct SourceWindowSizePolicyTests {
    static func main() {
        let display=CGRect(x:0,y:0,width:1440,height:900)
        let capture=CGRect(x:1000,y:600,width:320,height:180)
        let window=capture
        let result=SourceWindowSizePolicy.frame(frame:window,capture:capture,display:display,pixels:CGSize(width:1280,height:720),scale:2)!
        precondition(result == CGRect(x:800,y:540,width:640,height:360))
        let same=SourceWindowSizePolicy.frame(frame:CGRect(x:100,y:80,width:320,height:200),capture:CGRect(x:100,y:100,width:320,height:180),display:display,pixels:CGSize(width:1280,height:720),scale:2)!
        precondition(same == CGRect(x:100,y:80,width:640,height:380))
        precondition(SourceWindowSizePolicy.frame(frame:window,capture:capture,display:display,pixels:CGSize(width:4000,height:3000),scale:1) == nil)
        precondition(SourceWindowSizePolicy.frame(frame:window,capture:capture,display:display,pixels:CGSize(width:1280,height:720),scale:0) == nil)
        precondition(SourceWindowSizePolicy.freshFrame(host:101,after:100,frameGeneration:3,currentGeneration:3,frameWindow:7,targetWindow:7))
        precondition(!SourceWindowSizePolicy.freshFrame(host:100,after:100,frameGeneration:3,currentGeneration:3,frameWindow:7,targetWindow:7))
        precondition(!SourceWindowSizePolicy.freshFrame(host:101,after:100,frameGeneration:2,currentGeneration:3,frameWindow:7,targetWindow:7))
        precondition(!SourceWindowSizePolicy.freshFrame(host:101,after:100,frameGeneration:3,currentGeneration:3,frameWindow:8,targetWindow:7))
        print("source window size policy: retina, minimal placement, geometry and stale frame cases pass")
    }
}
