//
//  AppleSiliconDDCBridge.swift
//  BtnQ
//
//  Swift declarations for the private CoreDisplay / IOKit symbols that
//  AppleSiliconDDC.swift relies on. Upstream ships these via an Objective-C
//  bridging header (AppleSiliconDDCObjC); declaring them with @_silgen_name lets
//  us vendor a single Swift file into an app target with no bridging header.
//
//  These symbols are exported by CoreDisplay.framework (linked via the
//  "-framework CoreDisplay" linker flag). They are private API.
//

import CoreGraphics
import Foundation
import IOKit

public typealias IOAVService = CFTypeRef

@_silgen_name("IOAVServiceCreateWithService")
func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<CFTypeRef>?

@_silgen_name("IOAVServiceReadI2C")
func IOAVServiceReadI2C(_ service: IOAVService?, _ chipAddress: UInt32, _ offset: UInt32, _ outputBuffer: UnsafeMutableRawPointer?, _ outputBufferSize: UInt32) -> IOReturn

@_silgen_name("IOAVServiceWriteI2C")
func IOAVServiceWriteI2C(_ service: IOAVService?, _ chipAddress: UInt32, _ dataAddress: UInt32, _ inputBuffer: UnsafeMutableRawPointer?, _ inputBufferSize: UInt32) -> IOReturn

@_silgen_name("CoreDisplay_DisplayCreateInfoDictionary")
func CoreDisplay_DisplayCreateInfoDictionary(_ display: CGDirectDisplayID) -> Unmanaged<CFDictionary>?

// macOS system "High Dynamic Range" toggle (System Settings ▸ Displays ▸ HDR).
@_silgen_name("CoreDisplay_Display_IsHDRModeEnabled")
func CoreDisplay_Display_IsHDRModeEnabled(_ display: CGDirectDisplayID) -> Bool

@_silgen_name("CoreDisplay_Display_SetHDRModeEnabled")
func CoreDisplay_Display_SetHDRModeEnabled(_ display: CGDirectDisplayID, _ enabled: Bool)
