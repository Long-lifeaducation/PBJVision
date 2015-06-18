//
//  VideoFrameProfiler.m
//  Pods
//
//  Created by Joel Davis on 6/10/15.
//
//

#import "VideoFrameProfiler.h"

#include <mach/mach.h>
#include <mach/mach_time.h>


#define MAX_EVENTS (100000)

typedef struct FrameEventStruct
{
    CFAbsoluteTime timestamp;
    uint32_t descIndex;
    uint32_t frameNumber;
    
} FrameEvent;

@interface StringTable : NSObject
@property (nonatomic, strong) NSMutableArray *stringList;
@property (nonatomic, strong) NSMutableDictionary *stringIndex;
- (id)init;
- (uint32_t)lookup: (NSString*)string;
@end

@implementation StringTable
- (id)init
{
    self = [super init];
    if (self)
    {
        self.stringList = [NSMutableArray array];
        self.stringIndex = [NSMutableDictionary dictionary];
    }
    return self;
}

- (uint32_t)lookup: (NSString*)string
{
    uint32_t result;
    NSNumber *index = [_stringIndex objectForKey:string];
    if (!index) {
        result = _stringList.count;
        [_stringList addObject:string];
        [_stringIndex setObject:[NSNumber numberWithInteger:result] forKey:string];
    } else {
        result = [index integerValue];
    }
    return result;
}

- (void) clear
{
    [self.stringList removeAllObjects];
    [self.stringIndex removeAllObjects];
}

@end

@interface VideoFrameProfiler ()
{
    uint32_t _frameNum;
    CFAbsoluteTime _startTime;
    size_t _numEvents;
    FrameEvent *_events;
    
}
@property (nonatomic, strong) StringTable *descTable;
@property (nonatomic, strong) NSData *eventData;
@end

@implementation VideoFrameProfiler

+ (VideoFrameProfiler*)sharedProfiler
{
    static dispatch_once_t onceToken;
    static VideoFrameProfiler *profiler;
    dispatch_once(&onceToken, ^{
        profiler = [[VideoFrameProfiler alloc] init];
    });
    return profiler;
}

- (id) init
{
    self = [super init];
    if (self)
    {
        self.descTable = [[StringTable alloc] init];
        size_t eventDataSize = sizeof(FrameEvent)*MAX_EVENTS;
        void *eventRawData = malloc(eventDataSize);
        self.eventData = [NSData dataWithBytesNoCopy:eventRawData length:eventDataSize];
        _events = (FrameEvent *)self.eventData.bytes;
        _numEvents = 0;
    }
    return self;
}

- (void) reset
{
    [self.descTable clear];
    _numEvents = 0;
    _frameNum = 0;
    _startTime = CFAbsoluteTimeGetCurrent();
}

- (void)beginNextFrame
{
    [self beginFrame: _frameNum+1 ];
}

- (void)beginFrame: (uint32_t)frameNumber
{
    _frameNum = frameNumber;
    [self addFrameEvent: @"frame-begin"];
}

- (void)addFrameEvent: (NSString*)desc
{
    // FIXME: Not threadsafe.
    FrameEvent *evt = _events + _numEvents++;
                       
//    evt->timestamp = mach_absolute_time();
    evt->timestamp = CFAbsoluteTimeGetCurrent() - _startTime;
    evt->descIndex = [self.descTable lookup:desc];
    evt->frameNumber = _frameNum;
}

- (void)writeVideoLog: (NSString*)vidlog
{
    // Just write a text file for now, to make
    // things easier to process, if this gets unweildly
    // can just write the raw data
    NSLog( @"Write video log: %@", vidlog );
    FILE *fp = fopen( [vidlog UTF8String], "wt" );
    // String table
    uint32_t index = 0;
    for (NSString *s in self.descTable.stringList)
    {
        fprintf( fp, "st %d:%s\n", index, [s UTF8String] );
        index++;
    }
    // Events
    for (uint32_t evndx=0; evndx < _numEvents; evndx++)
    {
        FrameEvent *ev = _events + evndx;
        fprintf( fp, "e %lf %u %u\n", ev->timestamp, ev->frameNumber, ev->descIndex );
    }
    fclose( fp );
}


@end
