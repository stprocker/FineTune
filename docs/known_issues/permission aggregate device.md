
  When you click "Allow" on the permission dialog, the app destroys all aggregate devices and    
  recreates them. Destroying those aggregates causes macOS to fire a spurious                    
  kAudioHardwarePropertyDefaultOutputDevice change notification (briefly seeing MacBook Pro      
  Speakers as default since the AirPods aggregate was just torn down). That notification was     
  calling routeAllApps(to: macbookProUID), overwriting the correct per-app routing.              

  The fix adds an isRecreatingTaps flag that's set true during both recreateAllTaps() (permission confirmation) and handleServiceRestarted() (coreaudiod restart). While the flag is set, the onDefaultDeviceChangedExternally callback logs and ignores the notification instead of rerouting everything.