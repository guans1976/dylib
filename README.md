# V3.3 Active Path Trace

这版不再扫描 4 万多个类，而是直接参照 V20 的真实 WebRTC/HWLLS 链路，Hook “是否被调用”。

观察对象：
- IJKFFMoviePlayerController
- HLLLManager: playStream / setCurrentUrl / initClient / stop
- HWLLSClientProxy:
  createPeerConnection
  setLocalSDP
  setRemoteSDP
  prepareStartPlay
  playSignalingRequest
  playRequestWithDnsResult
  sendSignalingWithDnsResult:isStop:
  startPlay:startPlayOptions:
- HWLLSManager:
  setSignalingHost / setSignalingPort / setSignalingType / setDomain / setTargetDomain

输出：
- Documents/PaidPreviewV3_3_ActivePathTrace.log
- Documents/preview_v3_3_active_path.json

分类：
- preview_http_flv_active_only
- dual_path_actively_called
- v20_path_actively_called
- unknown

建议测试两次：
1. 收费预览页一次
2. 普通正常播放页一次
分别导出两组 log/json，用于直接对照。
