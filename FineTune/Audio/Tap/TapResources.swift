// FineTune/Audio/Tap/TapResources.swift
import AudioToolbox

/// Encapsulates Core Audio tap and aggregate device resources.
/// Provides safe cleanup with correct teardown order.
struct TapResources {
    var tapID: AudioObjectID = .unknown
    var aggregateDeviceID: AudioObjectID = .unknown
    var deviceProcID: AudioDeviceIOProcID?
    var tapDescription: CATapDescription?

    /// Whether these resources are currently active
    var isActive: Bool {
        tapID.isValid || aggregateDeviceID.isValid
    }

    /// Destroys all resources in the correct order to prevent leaks and crashes.
    ///
    /// **Teardown order is critical:**
    /// 1. Stop device proc (AudioDeviceStop)
    /// 2. Destroy IO proc ID (AudioDeviceDestroyIOProcID)
    /// 3. Destroy aggregate device (AudioHardwareDestroyAggregateDevice)
    /// 4. Destroy process tap (AudioHardwareDestroyProcessTap)
    ///
    /// Violating this order can leak resources or crash on shutdown.
    mutating func destroy() {
        // Step 1 & 2: Stop and destroy IO proc
        if aggregateDeviceID.isValid {
            if let procID = deviceProcID {
                AudioDeviceStop(aggregateDeviceID, procID)
                AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            }
        }
        deviceProcID = nil

        // Step 3: Destroy aggregate device
        if aggregateDeviceID.isValid {
            CrashGuard.untrackDevice(aggregateDeviceID)
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }
        aggregateDeviceID = .unknown

        // Step 4: Destroy process tap
        if tapID.isValid {
            AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = .unknown

        tapDescription = nil
    }

    /// Destroys resources asynchronously on a background queue.
    /// Use this when destruction might block (e.g., AudioDeviceDestroyIOProcID
    /// blocks until the callback finishes).
    ///
    /// - Parameters:
    ///   - queue: Queue to perform destruction on (default: global utility)
    ///   - completion: Optional callback invoked after all resources are destroyed
    mutating func destroyAsync(on queue: DispatchQueue = .global(qos: .utility), completion: (() -> Void)? = nil) {
        // Capture values before clearing
        let capturedTapID = tapID
        let capturedAggregateID = aggregateDeviceID
        let capturedProcID = deviceProcID

        // Clear instance state immediately
        tapID = .unknown
        aggregateDeviceID = .unknown
        deviceProcID = nil
        tapDescription = nil

        // Dispatch blocking teardown to background
        queue.async {
            // Step 1 & 2: Stop and destroy IO proc
            if capturedAggregateID.isValid, let procID = capturedProcID {
                AudioDeviceStop(capturedAggregateID, procID)
                AudioDeviceDestroyIOProcID(capturedAggregateID, procID)
            }

            // Step 3: Destroy aggregate device
            if capturedAggregateID.isValid {
                CrashGuard.untrackDevice(capturedAggregateID)
                AudioHardwareDestroyAggregateDevice(capturedAggregateID)
            }

            // Step 4: Destroy process tap
            if capturedTapID.isValid {
                AudioHardwareDestroyProcessTap(capturedTapID)
            }

            completion?()
        }
    }
}
