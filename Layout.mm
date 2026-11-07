/*
 *  Layout.mm
 *  MachOView
 *
 *  Created by Bugra Karabudak on 18/03/2011.
 *
 */

#import "Common.h"
#import "Document.h"
#import "DataController.h"
#import "Layout.h"

//============================================================================
@implementation MVLayout

@synthesize dataController, backgroundThread, archiver;

/*
- (void)dealloc
{
  NSLog(@"********MVLayout deallocated: %@", self);
}
*/



//-----------------------------------------------------------------------------
- (instancetype)initWithDataController:(MVDataController *)dc rootNode:(MVNode *)node
{
  if (self = [super init]) 
  {
    dataController = dc;
    rootNode = node;
    imageOffset = node.dataRange.location;
    imageSize = node.dataRange.length;
    // Nested archive members must observe the same cancellation as their parent.
    MVLayout * parentLayout = node.userInfo[MVLayoutUserInfoKey];
    backgroundThread = parentLayout.backgroundThread ?: [[NSThread alloc] init];
    NSString * swapPath = [[MVDocument temporaryDirectory]
                          stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
    if (swapPath == nil || (archiver = [MVArchiver archiverWithPath:swapPath]) == nil)
      [NSException raise:@"MVSwapFileError" format:@"Cannot create temporary swap file"];
  }
  return self;
}

//-----------------------------------------------------------------------------
- (void const *)imageAt:(uint64_t)location
{
  auto p = (uint8_t const *)(dataController.realData).bytes;
  return p ? p + location : NULL;
}

//-----------------------------------------------------------------------------
- (NSString *)description
{
  return [super.description stringByAppendingFormat:@" [%@]",rootNode.caption];
}

//-----------------------------------------------------------------------------
-(void)printException:(NSException *)exception caption:(NSString *)caption
{
  @synchronized([NSApp class])
  {
    NSLog(@"%@: Exception (%@): %@", self, caption, exception.name);
    NSLog(@"  Reason: %@", exception.reason);
    NSLog(@"  User Info: %@", exception.userInfo);
    NSLog(@"  Backtrace:\n%@", exception.callStackSymbols);
  }
}

//-----------------------------------------------------------------------------
- (BOOL)is64bit
{
  return NO;
}

//-----------------------------------------------------------------------------
- (void)doMainTasks
{
}

//-----------------------------------------------------------------------------
- (void)startBackgroundTasks
{
  static NSOperationQueue * queue;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    queue = [[NSOperationQueue alloc] init];
    queue.name = @"MachOView layout parsing";
    queue.maxConcurrentOperationCount = 2;
    queue.qualityOfService = NSQualityOfServiceUserInitiated;
  });
  // Keep backing data/root nodes alive until even cancelled operations finish.
  MVDataController * controller = dataController;
  [controller updateStatus:MVStatusTaskStarted];
  [queue addOperationWithBlock:^{
    @autoreleasepool
    {
      @try
      {
        if (!self->backgroundThread.cancelled) [self doBackgroundTasks];
      }
      @catch (NSException * exception)
      {
        [self printException:exception caption:@"Background processing"];
      }
      @finally
      {
        [self->archiver halt];
        [controller updateStatus:MVStatusTaskTerminated];
      }
    }
  }];
}

//-----------------------------------------------------------------------------
- (void)doBackgroundTasks
{
  [archiver halt];
}

//-----------------------------------------------------------------------------
- (NSString *)convertToRVA: (NSString *)offsetStr
{
  return @"";
}

//-----------------------------------------------------------------------------
// Depth-first Traversal of nodes
//-----------------------------------------------------------------------------
- (MVNode *)findNodeByUserInfo:(NSDictionary *)userInfo
{
  [dataController.treeLock lock];
  MVNode * node = [rootNode findNodeByUserInfo:userInfo];
  [dataController.treeLock unlock];
  
  return node;
}

//-----------------------------------------------------------------------------
// Create data node without details table (only hex content)
//-----------------------------------------------------------------------------
- (MVNode *)createDataNode:(MVNode *)parent
                   caption:(NSString *)caption
                  location:(uint64_t)location
                    length:(uint64_t)length
{
  MVNode * node = [parent insertChild:caption location:location length:length];
  return node;
}

@end
