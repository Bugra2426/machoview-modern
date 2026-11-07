// Native macOS regression tests, linked into MachOView and invoked by --self-test.
// No window, nib, sleep-based scheduling, or third-party test framework required.
#import <Cocoa/Cocoa.h>
#import "../DataController.h"
#import "../Layout.h"
#import "../Document.h"
#include <mach-o/loader.h>

@interface MVTable (DataControllerTests)
+ (MVTable *)tableWithArchiver:(MVArchiver *)archiver;
- (void)applyFilter:(NSString *)filter;
@end

static void MVCheck(BOOL condition, NSString * message)
{
  if (!condition) [NSException raise:@"MVRegressionFailure" format:@"%@", message];
}

static MVLayout * MVTestLayout(MVDataController * controller)
{
  MVLayout * layout = [[MVLayout alloc] initWithDataController:controller rootNode:controller.rootNode];
  controller.rootNode.userInfo[MVLayoutUserInfoKey] = layout;
  return layout;
}

static void MVTestRoundTrip(void)
{
  MVDataController * controller = [[MVDataController alloc] init];
  MVLayout * layout = MVTestLayout(controller);
  MVNode * node;
  NSString * unicode = @"café — 日本語 \U0001D11E";
  unichar characters[] = {'A', 0, 0x03BB};
  NSString * embeddedNUL = [NSString stringWithCharacters:characters length:3];
  {
    MVNodeSaver saver;
    node = [controller.rootNode insertChildWithDetails:@"Round trip" location:0 length:2 saver:saver];
    controller.selectedNode = node;
    [node.details appendRow:@"00000000" :@"11" :unicode :embeddedNUL];
    [node.details setAttributes:MVMetaDataAttributeName, @"first", MVUnderlineAttributeName, @"YES", nil];
    [node.details appendRow:@"00000001" :@"22" :@"Second" :@""];
    [node.details setAttributes:MVMetaDataAttributeName, @"café", MVTextColorAttributeName, [NSColor blueColor], nil];
  }
  [layout.archiver flush];
  MVCheck([layout.archiver canArchive] && node.detailsOffset != 0, @"Indexes must be saved at a nonzero offset");
  [node closeDetails];
  [node openDetails];
  [node filterDetails:nil];
  MVCheck(node.details.rowCountToDisplay == 2, @"Round-trip row count");
  MVRow * snapshot = [node.details getRowToDisplay:0];
  MVCheck([snapshot.coloumns.descriptionStr isEqualToString:unicode], @"Multibyte UTF-8 round trip");
  MVCheck([snapshot.coloumns.valueStr isEqualToString:embeddedNUL], @"Embedded NUL round trip");
  MVCheck([snapshot.attributes[MVUnderlineAttributeName] isEqualToString:@"YES"], @"Attribute round trip");

  // Dirty attributes must override, not be overwritten by the archived values.
  [node.details setAttributesForRowIndex:1 :MVTextColorAttributeName, [NSColor greenColor], nil];
  [layout.archiver flush];
  [node.details setAttributesForRowIndex:1 :MVTextColorAttributeName, [NSColor orangeColor], nil];
  [layout.archiver addObjectToSave:node];
  [layout.archiver flush];
  [node closeDetails];
  [node openDetails];
  [node filterDetails:@"CAFE"];
  MVCheck(node.details.rowCountToDisplay == 1, @"Case/diacritic-insensitive metadata filter");
  MVCheck([[[node.details getRowToDisplay:0] attributes][MVTextColorAttributeName] isEqual:[NSColor orangeColor]],
          @"Latest attributes win over both cached and archived values");

  [node.details updateDisplayedCellContentTo:@"FF" atRow:0 andCol:DATA_COLUMN];
  [layout.archiver addObjectToSave:node];
  [layout.archiver halt];
  [node closeDetails];
  [node openDetails];
  [node filterDetails:nil];
  MVCheck([[[node.details getRowToDisplay:0] coloumnAtIndex:DATA_COLUMN] isEqualToString:@"11"],
          @"Filtered editing must not modify the unfiltered first row");
  MVCheck([[[node.details getRowToDisplay:1] coloumnAtIndex:DATA_COLUMN] isEqualToString:@"FF"],
          @"Filtered edit and updated indexes survive eviction");
  MVCheck([snapshot.coloumns.descriptionStr isEqualToString:unicode], @"UI snapshots survive writer eviction");
  // halt is a drain, not a second concurrent writer path: edits still persist.
  [node.details updateDisplayedCellContentTo:@"AA" atRow:1 andCol:DATA_COLUMN];
  [layout.archiver addObjectToSave:node];
  [layout.archiver flush];
  [node closeDetails];
  [node openDetails];
  [node filterDetails:nil];
  MVCheck([[[node.details getRowToDisplay:1] coloumnAtIndex:DATA_COLUMN] isEqualToString:@"AA"], @"Edits after halt");
}

static void MVTestConcurrentProducers(void)
{
  MVDataController * controller = [[MVDataController alloc] init];
  MVLayout * layout = MVTestLayout(controller);
  NSMutableArray * nodes = [[NSMutableArray alloc] init];
  const NSUInteger producers = 6, rowCount = 900;
  for (NSUInteger producer = 0; producer < producers; ++producer)
  {
    MVNode * node = [controller.rootNode insertChild:@"Concurrent" location:producer length:0];
    node.details = [MVTable tableWithArchiver:layout.archiver];
    [nodes addObject:node];
  }
  dispatch_group_t group = dispatch_group_create();
  dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
  __block NSException * failure = nil;
  NSObject * failureLock = [[NSObject alloc] init];
  for (NSUInteger producer = 0; producer < producers; ++producer)
  {
    MVNode * node = nodes[producer];
    dispatch_group_async(group, queue, ^{
      @autoreleasepool
      {
        @try
        {
          MVTable * table = node.details;
          for (NSUInteger index = 0; index < rowCount; ++index)
          {
            @autoreleasepool
            {
              NSString * text = [NSString stringWithFormat:@"%lu/%lu 日本語", (unsigned long)producer, (unsigned long)index];
              [table appendRow:@"0" :@"00" :text :@""];
              [table setAttributes:MVMetaDataAttributeName, text, nil];
              if (index % 41 == 0)
              {
                [table applyFilter:nil];
                MVRow * row = [table getRowToDisplay:index];
                MVCheck([row.coloumns.descriptionStr isEqualToString:text], @"Read during concurrent archive flush");
              }
            }
          }
          [layout.archiver addObjectToSave:node];
        }
        @catch (NSException * exception)
        {
          @synchronized(failureLock) { failure = exception; }
        }
      }
    });
  }
  // Exercise simultaneous drains (the old halt/add path opened multiple writers).
  dispatch_group_async(group, queue, ^{ for (NSUInteger index = 0; index < 20; ++index) [layout.archiver flush]; });
  MVCheck(dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)) == 0,
          @"Concurrent producer test timed out");
  if (failure != nil) @throw failure;
  [layout.archiver flush];
  MVCheck([layout.archiver canArchive], @"Concurrent writes must not disable archiving");
  for (NSUInteger producer = 0; producer < producers; ++producer)
  {
    MVNode * node = nodes[producer];
    controller.selectedNode = node;
    [node openDetails];
    [node filterDetails:nil];
    MVCheck(node.details.rowCountToDisplay == rowCount, @"Concurrent index row count");
    for (NSUInteger index = 0; index < rowCount; ++index)
    {
      @autoreleasepool
      {
        NSString * expected = [NSString stringWithFormat:@"%lu/%lu 日本語", (unsigned long)producer, (unsigned long)index];
        MVRow * row = [node.details getRowToDisplay:index];
        MVCheck([row.coloumns.descriptionStr isEqualToString:expected], @"Concurrent row data integrity");
        MVCheck([row.attributes[MVMetaDataAttributeName] isEqualToString:expected], @"Concurrent metadata integrity");
      }
    }
    [node closeDetails];
  }
}

static void MVTestHeaderBounds(void)
{
  for (NSUInteger length = 0; length < sizeof(struct mach_header_64); ++length)
  {
    MVDataController * controller = [[MVDataController alloc] init];
    controller.fileData = [NSMutableData dataWithLength:length];
    if (length >= sizeof(uint32_t))
    {
      uint32_t magic = MH_MAGIC_64;
      memcpy(controller.fileData.mutableBytes, &magic, sizeof(magic));
    }
    BOOL rejected = NO;
    @try { [controller createLayouts:controller.rootNode location:0 length:length]; }
    @catch (NSException *) { rejected = YES; }
    MVCheck(rejected, @"Truncated headers must be rejected before dereferencing");
  }
  // A minimal host-compatible object exercises the main/background parser pipeline.
  struct mach_header_64 header = {};
  header.magic = MH_MAGIC_64;
#if defined(__arm64__)
  header.cputype = CPU_TYPE_ARM64;
  header.cpusubtype = CPU_SUBTYPE_ARM64_ALL;
#else
  header.cputype = CPU_TYPE_X86_64;
  header.cpusubtype = CPU_SUBTYPE_X86_64_ALL;
#endif
  header.filetype = MH_OBJECT;
  MVDataController * controller = [[MVDataController alloc] init];
  controller.fileData = [NSMutableData dataWithBytes:&header length:sizeof(header)];
  controller.realData = [controller.fileData mutableCopy];
  [controller createLayouts:controller.rootNode location:0 length:sizeof(header)];
  MVCheck(controller.layouts.count == 1, @"Native Mach-O layout dispatch");
  for (MVLayout * layout in controller.layouts)
  {
    [layout doMainTasks];
    [layout doBackgroundTasks];
    [layout.archiver flush];
    MVCheck([layout.archiver canArchive], @"Minimal native parser pipeline archives successfully");
  }
  MVCheck(controller.rootNode.numberOfChildren != 0, @"Parser creates header details");
}

int MVRunDataControllerTests(void)
{
  // A hard timeout also covers unexpected lock-order regressions in flush/load.
  dispatch_semaphore_t finished = dispatch_semaphore_create(0);
  __block int result = 1;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    @autoreleasepool
    {
      @try
      {
        MVTestRoundTrip();
        MVTestConcurrentProducers();
        MVTestHeaderBounds();
        NSLog(@"Data-controller regression tests passed");
        result = 0;
      }
      @catch (NSException * exception)
      {
        NSLog(@"Data-controller regression failure: %@: %@", exception.name, exception.reason);
      }
      @finally { dispatch_semaphore_signal(finished); }
    }
  });
  if (dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC)) != 0)
  {
    NSLog(@"Data-controller regression tests timed out after 60 seconds");
    return 1;
  }
  return result;
}
