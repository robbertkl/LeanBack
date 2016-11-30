//
//  AppDelegate.m
//  LeanBack
//
//  Created by Robbert Klarenbeek on 26/06/2015.
//  Copyright © 2015 LapuLapu. All rights reserved.
//

#import "AppDelegate.h"

@import AVFoundation;

typedef int CGSConnectionID;
CG_EXTERN CGSConnectionID CGSMainConnectionID(void);
CG_EXTERN CGError CGSGetZoomParameters(CGSConnectionID cid, CGPoint *pt, CGFloat *something, BOOL *smoothinEnabled);
CG_EXTERN CGError CGSSetZoomParameters(CGSConnectionID cid, CGPoint *pt, CGFloat something, BOOL smoothinEnabled);

typedef NS_ENUM(NSInteger, LeanMode) {
    LeanModeForward = 1,
    LeanModeBackward = 2,
};

NSInteger const kMovingAverageSize = 7;

static NSString * const kLeanMode = @"LeanMode";

@interface AppDelegate ()<AVCaptureVideoDataOutputSampleBufferDelegate>
@property (weak) IBOutlet NSMenu *menu;
@property (nonatomic, assign) LeanMode leanMode;
@end

@implementation AppDelegate {
    NSStatusItem *_statusItem;
    
    CGFloat _smoothing[kMovingAverageSize];
    int _currentIndex;
    CGFloat _sum;
    
    CGFloat _calibration;

    CGSConnectionID _connectionId;
    CIDetector *_faceDetector;
    AVCaptureSession *_session;
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
                                                              kLeanMode: @(LeanModeForward),
                                                              }];

    _leanMode = -1;
    self.leanMode = [[NSUserDefaults standardUserDefaults] integerForKey:kLeanMode];

    _statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    _statusItem.menu = self.menu;
    _statusItem.highlightMode = YES;
    _statusItem.image = [NSImage imageNamed:@"NSQuickLookTemplate"];
    
    [self calibrate:nil];
    
    [self setupCamera];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [[NSStatusBar systemStatusBar] removeStatusItem:_statusItem];
}

- (void)setLeanMode:(LeanMode)leanMode {
    if (_leanMode != leanMode) {
        _leanMode = leanMode;
        [[NSUserDefaults standardUserDefaults] setObject:@(_leanMode) forKey:kLeanMode];
        [[NSUserDefaults standardUserDefaults] synchronize];
        
        for (NSMenuItem *menuItem in _menu.itemArray) {
            if (menuItem.action != @selector(changeLeanMode:)) continue;
            menuItem.state = menuItem.tag == _leanMode ? 1 : 0;
        }
        
        [self calibrate:nil];
    }
}

- (IBAction)changeLeanMode:(NSMenuItem *)sender {
    self.leanMode = (LeanMode)sender.tag;
}

- (IBAction)calibrate:(NSMenuItem *)sender {
    _calibration = -1;
}

- (void)setupCamera {
    _connectionId = CGSMainConnectionID();
    
    _faceDetector = [CIDetector detectorOfType:CIDetectorTypeFace context:nil options:@{ CIDetectorAccuracy: CIDetectorAccuracyHigh }];
    
    _session = [[AVCaptureSession alloc] init];
    _session.sessionPreset = AVCaptureSessionPresetHigh;
    
    NSArray *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
    AVCaptureDevice *device = devices.firstObject;
    NSLog(@"Found %ld cameras, selecting %@", devices.count, device.localizedName);
    
    NSError *error;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    if (error) {
        NSLog(@"Error getting camera device: %@", error);
        return;
    }
    
    if ([_session canAddInput:input]) {
        [_session addInput:input];
    } else {
        NSLog(@"Error adding video input");
        return;
    }
    
    AVCaptureVideoDataOutput *output = [[AVCaptureVideoDataOutput alloc] init];
    dispatch_queue_t queue = dispatch_queue_create("nl.lapulapu.leanback", NULL);
    [output setSampleBufferDelegate:self queue:queue];
    
    if ([_session canAddOutput:output]) {
        [_session addOutput:output];
    } else {
        NSLog(@"Error adding video output");
        return;
    }
    
    [_session startRunning];
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!imageBuffer) return;
    
    CFDictionaryRef attachments = CMCopyDictionaryOfAttachments(kCFAllocatorDefault, sampleBuffer, kCMAttachmentMode_ShouldPropagate);
    CIImage *ciImage = [[CIImage alloc] initWithCVImageBuffer:imageBuffer options:(__bridge NSDictionary *)attachments];
    
    CIFaceFeature *closestFace = nil;
    for (CIFaceFeature *face in [_faceDetector featuresInImage:ciImage]) {
        if (closestFace == nil || face.bounds.size.width > closestFace.bounds.size.width) {
            closestFace = face;
        }
    }
    
    if (!closestFace) return;
    if (!closestFace.hasLeftEyePosition || !closestFace.hasRightEyePosition) return;
    CGFloat dx = (closestFace.rightEyePosition.x - closestFace.leftEyePosition.x);
    CGFloat dy = (closestFace.rightEyePosition.y - closestFace.leftEyePosition.y);
    CGFloat eyeDistance = sqrt((dx * dx) + (dy * dy));
    
    if (_calibration < 0) {
        _calibration = eyeDistance;
        
        _sum = 0;
        _currentIndex = 0;
        for (int i = 0; i < kMovingAverageSize; i++) {
            _smoothing[i] = 0;
        }
    }
    
    _sum -= _smoothing[_currentIndex];
    _smoothing[_currentIndex] = eyeDistance;
    _sum += _smoothing[_currentIndex];
    _currentIndex = (_currentIndex + 1) % kMovingAverageSize;
    
    if (_smoothing[kMovingAverageSize - 1] <= 0.1) {
        CGSSetZoomParameters(_connectionId, NULL, 1.0, YES);
        return;
    }
    
    CGFloat averageEyeDistance = _sum / kMovingAverageSize;
    
    CGFloat zoomLevel = 1;
    switch (_leanMode) {
        case LeanModeForward:
            zoomLevel = averageEyeDistance / _calibration;
            break;
        case LeanModeBackward:
            zoomLevel = _calibration / averageEyeDistance;
            break;
    }

    zoomLevel = MAX(pow(zoomLevel, 2.2), 1);
    CGSSetZoomParameters(_connectionId, NULL, zoomLevel, YES);
}

@end
