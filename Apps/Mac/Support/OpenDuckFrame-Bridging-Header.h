#ifndef OpenDuckFrame_Bridging_Header_h
#define OpenDuckFrame_Bridging_Header_h

#import "SPPlayerCore.h"
#import "SPCaptionAudioReader.h"
#import "SPCaptionSubtitleReader.h"
#import "SPLiveProcessor.h"
#import "SPFRCEngine.h"
#import "SPAppleLowLatencySR.h"
#import "SPAppleVideoSR.h"
#import "SPAnime4K.h"
#import "SPRealCUGAN.h"
#import "SPArtCNNSR.h"
#import "SPDistilDRBA.h"
#import "SPFileRifeEngine.h"
#import "SPFileLowLatencyEngine.h"
#import "SPFileDistilEngine.h"

#ifdef __cplusplus
extern "C"
#endif
void SPPrewarmMetalDevice(void);

#ifdef __cplusplus
extern "C"
#endif
void SPPrewarmVideoDecoders(void);

#endif
