//
//  PBJVideoPlayerController.m
//
//  Created by Patrick Piemonte on 5/27/13.
//  Copyright (c) 2013. All rights reserved.
//

#import "PBJVideoPlayerController.h"
#import "PBJVideoView.h"

#import <AVFoundation/AVFoundation.h>

#define LOG_PLAYER 0
#if !defined(NDEBUG) && LOG_PLAYER
#   define DLog(fmt, ...) NSLog((@"player: " fmt), ##__VA_ARGS__);
#else
#   define DLog(...)
#endif

static NSString * const PBJVideoPlayerObserverContext = @"PBJVideoPlayerObserverContext";
static NSString * const PBJVideoPlayerItemObserverContext = @"PBJVideoPlayerItemObserverContext";

static NSString * const PBJVideoPlayerControllerTracksKey = @"tracks";
static NSString * const PBJVideoPlayerControllerStatusKey = @"status";
static NSString * const PBJVideoPlayerControllerPlayableKey = @"playable";
static NSString * const PBJVideoPlayerControllerDurationKey = @"duration";
static NSString * const PBJVideoPlayerControllerRateKey = @"rate";
static NSString * const PBJVideoPlayerControllerEmptyBufferKey = @"playbackBufferEmpty";
static NSString * const PBJVideoPlayerControllerPlayerKeepUpKey = @"playbackLikelyToKeepUp";

static NSInteger const PBJVideoPlayerRateCount = 6;
static float const PBJVideoPlayerControllerRates[PBJVideoPlayerRateCount] = { 0.25, 0.5, 0.75, 1, 1.5, 2 };

@interface PBJVideoPlayerController () <
    UIGestureRecognizerDelegate>
{
    AVAsset *_asset;
    AVPlayer *_player;
    AVPlayerItem *_playerItem;

    NSString *_videoPath;
    PBJVideoView *_videoView;

    PBJVideoPlayerPlaybackState _playbackState;
    PBJVideoPlayerBufferingState _bufferingState;
    
    // flags
    struct {
        unsigned int readyForPlayback:1;
    } __block _flags;
}

@end

@implementation PBJVideoPlayerController

@synthesize delegate = _delegate;
@synthesize videoPath = _videoPath;
@synthesize playbackState = _playbackState;
@synthesize bufferingState = _bufferingState;

#pragma mark - getters/setters

- (NSString *)videoPath
{
    return _videoPath;
}

- (void)setVideoPath:(NSString *)videoPath
{
    if (!videoPath || [videoPath length] == 0)
        return;

    NSURL *videoURL = [NSURL URLWithString:videoPath];
    if (!videoURL || ![videoURL scheme]) {
        videoURL = [NSURL fileURLWithPath:videoPath];
    }
    _videoPath = videoPath;

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:videoURL options:nil];
    [self _setAsset:asset];
}

- (void)_setAsset:(AVAsset *)asset
{
    if (_asset == asset)
        return;
    
    _flags.readyForPlayback = NO;

    if (_playbackState == PBJVideoPlayerPlaybackStatePlaying) {
        [self pause];
    }

    _bufferingState = PBJVideoPlayerBufferingStateUnknown;
    _asset = asset;

    if (!_asset) {
        [self _setPlayerItem:nil];
    }
    
    NSArray *keys = @[PBJVideoPlayerControllerTracksKey, PBJVideoPlayerControllerPlayableKey, PBJVideoPlayerControllerDurationKey];
    
    [_asset loadValuesAsynchronouslyForKeys:keys completionHandler:^{
        [self _executeBlockOnMainQueue:^{
        
            // check the keys
            for (NSString *key in keys) {
                NSError *error = nil;
                AVKeyValueStatus keyStatus = [asset statusOfValueForKey:key error:&error];
                if (keyStatus == AVKeyValueStatusFailed) {
                    _playbackState = PBJVideoPlayerPlaybackStateFailed;
                    [_delegate videoPlayerPlaybackStateDidChange:self];
                    return;
                }
            }

            // check playable
            if (!_asset.playable) {
                _playbackState = PBJVideoPlayerPlaybackStateFailed;
                [_delegate videoPlayerPlaybackStateDidChange:self];
                return;
            }

            // setup player
            AVPlayerItem *playerItem = [AVPlayerItem playerItemWithAsset:_asset];
            [self _setPlayerItem:playerItem];
            
        }];
    }];
}

- (void)_setPlayerItem:(AVPlayerItem *)playerItem
{
    if (_playerItem == playerItem)
        return;
    
    if (_playerItem) {
        // AVPlayerItem KVO
        [_playerItem removeObserver:self forKeyPath:PBJVideoPlayerControllerEmptyBufferKey context:(__bridge void *)(PBJVideoPlayerItemObserverContext)];
        [_playerItem removeObserver:self forKeyPath:PBJVideoPlayerControllerPlayerKeepUpKey context:(__bridge void *)(PBJVideoPlayerItemObserverContext)];
        [_playerItem removeObserver:self forKeyPath:PBJVideoPlayerControllerStatusKey context:(__bridge void *)(PBJVideoPlayerItemObserverContext)];

        // notifications
        [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:_playerItem];
        [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemFailedToPlayToEndTimeNotification object:_playerItem];
    }
    
    _playerItem = playerItem;
    
    if (_playerItem) {
        // AVPlayerItem KVO
        [_playerItem addObserver:self forKeyPath:PBJVideoPlayerControllerEmptyBufferKey options:(NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld) context:(__bridge void *)(PBJVideoPlayerItemObserverContext)];
        [_playerItem addObserver:self forKeyPath:PBJVideoPlayerControllerPlayerKeepUpKey options:(NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld) context:(__bridge void *)(PBJVideoPlayerItemObserverContext)];
        [_playerItem addObserver:self forKeyPath:PBJVideoPlayerControllerStatusKey options:(NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld) context:(__bridge void *)(PBJVideoPlayerItemObserverContext)];
        
        // notifications
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_playerItemDidPlayToEndTime:) name:AVPlayerItemDidPlayToEndTimeNotification object:_playerItem];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_playerItemFailedToPlayToEndTime:) name:AVPlayerItemFailedToPlayToEndTimeNotification object:_playerItem];
    }

    [_player replaceCurrentItemWithPlayerItem:_playerItem];
}

#pragma mark - init

- (id)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil
{
    self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];
    if (self) {
        // AVPlayer
        _player = [[AVPlayer alloc] init];
        _player.actionAtItemEnd = AVPlayerActionAtItemEndPause;
        
        // AVPlayer KVO
        [_player addObserver:self forKeyPath:PBJVideoPlayerControllerRateKey options:(NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld) context:(__bridge void *)(PBJVideoPlayerObserverContext)];
        
        // Application NSNotifications
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];        
        [nc addObserver:self selector:@selector(_applicationWillResignActive:) name:UIApplicationWillResignActiveNotification object:nil];
        [nc addObserver:self selector:@selector(_applicationWillEnterForeground:) name:UIApplicationWillEnterForegroundNotification object:nil];
        [nc addObserver:self selector:@selector(_applicationDidEnterBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    }
    return self;
}

- (void)dealloc
{
    _videoView.player = nil;
    _delegate = nil;

    // notifications
    [[NSNotificationCenter defaultCenter] removeObserver:self];

    // AVPlayer KVO
    [_player removeObserver:self forKeyPath:PBJVideoPlayerControllerRateKey context:(__bridge void *)PBJVideoPlayerObserverContext];

    // player
    [_player pause];
    
    // player item
    [self _setPlayerItem:nil];
}

#pragma mark - view lifecycle

- (void)loadView
{
    [super loadView];
    
    // setup the internal views
    _videoView = [[PBJVideoView alloc] initWithFrame:CGRectZero];
    _videoView.videoFillMode = AVLayerVideoGravityResizeAspect;
    _videoView.playerLayer.hidden = YES;
    self.view = _videoView;
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    
    [_player pause];
}

#pragma mark - private methods

- (void)_videoPlayerAudioSessionActive:(BOOL)active
{
    NSString *category = active ? AVAudioSessionCategoryPlayback : AVAudioSessionCategoryAmbient;
    
    NSError *error = nil;
    [[AVAudioSession sharedInstance] setCategory:category error:&error];
    if (error) {
        DLog(@"audio session active error (%@)", error);
    }
}

- (void)_updatePlayerRatio
{
}

#pragma mark - public methods

- (void)playFromBeginning
{
    DLog(@"playing from beginnging...");
    
    [_delegate videoPlayerPlaybackWillStartFromBeginning:self];
    [_player seekToTime:kCMTimeZero];
    [self play];
}

- (void)play
{
    DLog(@"playing...");
    
    _playbackState = PBJVideoPlayerPlaybackStatePlaying;
    [_delegate videoPlayerPlaybackStateDidChange:self];
    [_player play];
}

- (void)pause
{
    if (_playbackState != PBJVideoPlayerPlaybackStatePlaying)
        return;
    
    DLog(@"pause");
    
    [_player pause];
    _playbackState = PBJVideoPlayerPlaybackStatePaused;
    [_delegate videoPlayerPlaybackStateDidChange:self];
}

- (void)stop
{
    if (_playbackState != PBJVideoPlayerPlaybackStatePlaying)
        return;

    DLog(@"stop");
    
    [_player pause];
    _playbackState = PBJVideoPlayerPlaybackStateStopped;
    [_delegate videoPlayerPlaybackStateDidChange:self];
    
    [_delegate videoPlayerPlaybackDidEnd:self];
}

#pragma mark - main queue helper

typedef void (^PBJVideoPlayerBlock)();

- (void)_executeBlockOnMainQueue:(PBJVideoPlayerBlock)block {
    dispatch_sync(dispatch_get_main_queue(), ^{
        block();
    });
}

#pragma mark - UIResponder

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event
{
    if (_videoPath) {
        
        switch (_playbackState) {
            case PBJVideoPlayerPlaybackStateStopped:
            {
                [self playFromBeginning];
                break;
            }
            case PBJVideoPlayerPlaybackStatePaused:
            {
                [self play];
                break;
            }
            case PBJVideoPlayerPlaybackStatePlaying:
            case PBJVideoPlayerPlaybackStateFailed:
            default:
            {
                [self pause];
                break;
            }
        }
        
    } else {
        [super touchesEnded:touches withEvent:event];
    }
    
}

- (void)_handleTap:(UIGestureRecognizer *)gestureRecognizer
{
    if (_playbackState == PBJVideoPlayerPlaybackStatePlaying) {
        [self pause];
    } else if (_playbackState == PBJVideoPlayerPlaybackStateStopped) {
        [self playFromBeginning];
    } else {
        [self play];
    }
}

#pragma mark - AV NSNotificaions

- (void)_playerItemDidPlayToEndTime:(NSNotification *)aNotification
{
    [_player seekToTime:kCMTimeZero];
    [self stop];
}

- (void)_playerItemFailedToPlayToEndTime:(NSNotification *)aNotification
{
    _playbackState = PBJVideoPlayerPlaybackStateFailed;
    [_delegate videoPlayerPlaybackStateDidChange:self];
    DLog(@"error (%@)", [[aNotification userInfo] objectForKey:AVPlayerItemFailedToPlayToEndTimeErrorKey]);
}

#pragma mark - App NSNotifications

- (void)_applicationWillResignActive:(NSNotification *)aNotfication
{
    if (_playbackState == PBJVideoPlayerPlaybackStatePlaying)
        [self pause];
}

- (void)_applicationWillEnterForeground:(NSNotification *)aNotfication
{
}

- (void)_applicationDidEnterBackground:(NSNotification *)aNotfication
{
    if (_playbackState == PBJVideoPlayerPlaybackStatePlaying)
        [self pause];
}

#pragma mark - KVO

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if ( context == (__bridge void *)(PBJVideoPlayerObserverContext) ) {
    
    
    } else if ( context == (__bridge void *)(PBJVideoPlayerItemObserverContext) ) {
    
        if (_playerItem.playbackBufferEmpty) {
            DLog(@"playback buffer is empty");
        }

        AVPlayerStatus status = [[change objectForKey:NSKeyValueChangeNewKey] integerValue];
        switch (status)
        {
            case AVPlayerStatusReadyToPlay:
            {
                _videoView.playerLayer.backgroundColor = [[UIColor blackColor] CGColor];
                [_videoView.playerLayer setPlayer:_player];
                _videoView.playerLayer.hidden = NO;
                [_delegate videoPlayerReady:self];
                break;
            }
            case AVPlayerStatusFailed:
            {
                _playbackState = PBJVideoPlayerPlaybackStateFailed;
                [_delegate videoPlayerPlaybackStateDidChange:self];
                break;
            }
            case AVPlayerStatusUnknown:
            default:
                break;
        }
        
    } else {
    
		[super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
	
    }
}

@end
