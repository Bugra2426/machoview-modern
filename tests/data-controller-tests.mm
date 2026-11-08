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

// Collect every node of the tree, using the same thread-safe accessors as the UI.
static void MVCollectNodes(MVNode * node, NSMutableArray * nodes)
{
  [nodes addObject:node];
  for (NSUInteger index = 0; index < node.numberOfChildren; ++index)
  {
    MVNode * child = [node childAtIndex:index];
    if (child != nil) MVCollectNodes(child, nodes);
  }
}

// Mimic a user clicking through the tree (outlineViewSelectionDidChange) and
// scrolling the details table while the background parser is still running.
static void MVBrowseLikeUI(MVDataController * controller, NSUInteger pass)
{
  NSMutableArray * nodes = [[NSMutableArray alloc] init];
  MVCollectNodes(controller.rootNode, nodes);
  for (MVNode * node in nodes)
  {
    @autoreleasepool
    {
      MVNode * previous = controller.selectedNode;
      if (previous == node) continue;
      [previous closeDetails];
      controller.selectedNode = node;
      [node openDetails];
      [node filterDetails:(pass % 3 == 2) ? @"_main" : nil];
      MVTable * details = node.details;
      if (details == nil)
      {
        (void)node.dataRange; // hex view: data comes straight from fileData
        continue;
      }
      NSUInteger count = MIN(details.rowCountToDisplay, (NSUInteger)256);
      for (NSUInteger row = 0; row < count; ++row)
      {
        MVRow * displayed = [details getRowToDisplay:row];
        (void)[displayed coloumnAtIndex:DESCRIPTION_COLUMN];
        (void)displayed.attributes;
      }
    }
  }
  [controller.selectedNode closeDetails];
  controller.selectedNode = nil;
}

// Open a real file exactly like -[MVDocument readFromURL:] and
// -windowControllerDidLoadNib:, then browse it while it is still loading.
static void MVTestRealBinary(NSString * path)
{
  NSLog(@"Real-binary test: %@", path);
  MVDataController * controller = [[MVDataController alloc] init];
  controller.fileName = path;
  NSError * error = nil;
  controller.fileData = [NSMutableData dataWithContentsOfURL:[NSURL fileURLWithPath:path]
                                                     options:NSDataReadingMappedIfSafe
                                                       error:&error];
  MVCheck(controller.fileData != nil, [NSString stringWithFormat:@"Cannot read %@: %@", path, error]);
  controller.realData = [controller.fileData mutableCopy];
  [controller createLayouts:controller.rootNode location:0 length:controller.fileData.length];
  MVCheck(controller.layouts.count != 0, [NSString stringWithFormat:@"No layouts for %@", path]);

  __block int64_t active = 0;
  id observer = [[NSNotificationCenter defaultCenter]
    addObserverForName:MVThreadStateChangedNotification object:controller queue:nil
            usingBlock:^(NSNotification * note) {
              NSString * state = note.userInfo[MVStatusUserInfoKey];
              if ([state isEqualToString:MVStatusTaskStarted]) __atomic_add_fetch(&active, 1, __ATOMIC_SEQ_CST);
              else if ([state isEqualToString:MVStatusTaskTerminated]) __atomic_sub_fetch(&active, 1, __ATOMIC_SEQ_CST);
            }];
  @try
  {
    for (MVLayout * layout in controller.layouts) [layout doMainTasks];
    for (MVLayout * layout in controller.layouts) [layout startBackgroundTasks];

    NSDate * deadline = [NSDate dateWithTimeIntervalSinceNow:240];
    for (NSUInteger pass = 0; __atomic_load_n(&active, __ATOMIC_SEQ_CST) > 0; ++pass)
    {
      MVCheck([deadline timeIntervalSinceNow] > 0,
              [NSString stringWithFormat:@"Background parsing of %@ did not finish", path]);
      MVBrowseLikeUI(controller, pass);
      [NSThread sleepForTimeInterval:0.01];
    }
    // And once more after everything has been archived to the swap file.
    for (MVLayout * layout in controller.layouts) [layout.archiver flush];
    MVBrowseLikeUI(controller, 0);
    MVBrowseLikeUI(controller, 2);
    for (MVLayout * layout in controller.layouts)
      MVCheck([layout.archiver canArchive], [NSString stringWithFormat:@"Archiving failed for %@", path]);
    MVCheck(controller.rootNode.numberOfChildren != 0, [NSString stringWithFormat:@"Empty tree for %@", path]);
  }
  @finally
  {
    [[NSNotificationCenter defaultCenter] removeObserver:observer];
    for (MVLayout * layout in controller.layouts) [layout.backgroundThread cancel];
  }
}

static void MVTestRealBinaries(void)
{
  NSMutableArray<NSString *> * paths = [NSMutableArray arrayWithObjects:
    NSBundle.mainBundle.executablePath ?: @"",  // universal app: fat + arm64 + x86_64
    @"/bin/ls",                                  // system arm64e/x86_64 executable
    @"/usr/lib/dyld",                            // large system binary on disk
    nil];
  // CI adds e.g. a static archive: MV_SELFTEST_FILES=/path/a.a:/path/b
  NSString * extra = NSProcessInfo.processInfo.environment[@"MV_SELFTEST_FILES"];
  if (extra.length != 0) [paths addObjectsFromArray:[extra componentsSeparatedByString:@":"]];
  for (NSString * path in paths)
  {
    if (path.length == 0 || ![[NSFileManager defaultManager] isReadableFileAtPath:path])
    {
      NSLog(@"Real-binary test: skipping unreadable %@", path);
      continue;
    }
    @autoreleasepool { MVTestRealBinary(path); }
  }
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
        MVTestRealBinaries();
        NSLog(@"Real-binary loading tests passed");
        result = 0;
      }
      @catch (NSException * exception)
      {
        NSLog(@"Data-controller regression failure: %@: %@", exception.name, exception.reason);
      }
      @finally { dispatch_semaphore_signal(finished); }
    }
  });
  if (dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 600 * NSEC_PER_SEC)) != 0)
  {
    NSLog(@"Data-controller regression tests timed out after 600 seconds");
    return 1;
  }
  return result;
}
