/*
 *  MVDocument.mm
 *  MachOView
 *
 *  Created by Bugra Karabudak on 15/06/2010.
 *
 */

#import "Common.h"
#import "Document.h"
#import "DataController.h"
#import "Layout.h"
#include <unistd.h>

//============================================================================
@implementation MVOutlineView

/*
//----------------------------------------------------------------------------
- (void)mouseDown:(NSEvent *)theEvent
{
  // Control+Click invokes that the selected node will not be swapped out
  if ([theEvent modifierFlags] & NSControlKeyMask)
  {
    NSPoint event_location = [theEvent locationInWindow];
    NSPoint local_point = [self convertPoint:event_location fromView:nil];
    MVNode * node = [self itemAtRow:[self rowAtPoint:local_point]];
    
    // note: offset should not be zero for explicit change of dirty indicator
    if (node.details != nil)
    {
      node.dirty = !node.dirty;
      [self reloadItem:node];
      NSLog(@"%@: node: %@ becomes %@", self, node, node.dirty ? @"dirty" : @"clean");
    }
  }

  [super mouseDown:theEvent];
}
*/

@end


//============================================================================
@implementation MVTableView

//----------------------------------------------------------------------------
- (void)drawGridInClipRect:(NSRect)clipRect
{
  MVDocument * document = self.window.windowController.document;
  
  NSRange rowRange = [self rowsInRect:clipRect];
  
  // Adjust column range, always go from zero, so we can gather columns even to 
  // the left of what we are supposed to draw.
  [[NSColor grayColor] set];
  for (NSUInteger rowIndex = rowRange.location ;
       rowIndex < NSMaxRange(rowRange) ;
       rowIndex++ )
  {
    MVRow * row = [document.dataController.selectedNode.details getRowToDisplay:rowIndex];
    if (row == nil)
    {
      continue;
    }
    
    if ([(row.attributes)[MVUnderlineAttributeName] isEqualToString:@"YES"])
    {
      NSRect rowRect = [self rectOfRow:rowIndex];
      
      [NSBezierPath strokeLineFromPoint:NSMakePoint(rowRect.origin.x,
                                                    -0.5+rowRect.origin.y+rowRect.size.height)
                                toPoint:NSMakePoint(rowRect.origin.x + rowRect.size.width,
                                                    -0.5+rowRect.origin.y+rowRect.size.height)];
    }
  }
  //[super drawGridInClipRect:clipRect];
}

//----------------------------------------------------------------------------
- (void)highlightSelectionInClipRect:(NSRect)clipRect
{
  MVDocument * document = self.window.windowController.document;
  
  NSRange rowRange = [self rowsInRect:clipRect];
  
  for (NSUInteger rowIndex = rowRange.location ;
       rowIndex < NSMaxRange(rowRange) ;
       rowIndex++ )
  {
    MVRow * row = [document.dataController.selectedNode.details getRowToDisplay:rowIndex];
    if (row == nil)
    {
      continue;
    }
    
    NSColor * color = (row.attributes)[MVCellColorAttributeName];
    if (color != nil)
    {      
      NSColor * bgcolor = [NSColor controlAlternatingRowBackgroundColors][rowIndex % 2];
      
      [[color blendedColorWithFraction:0.85f ofColor:bgcolor] setFill];
      
      NSRect rowRect = [self rectOfRow:rowIndex];
      NSRectFill (rowRect);
    }
  }
  [super highlightSelectionInClipRect: clipRect];
}

//----------------------------------------------------------------------------
- (void)cancelOperation:(id)sender
{
  // I have no idea why NSTableView (or one of its parents) does not implement
  // 'cancel editing' functionality by default....
  // so, let's do it for ourselves
  
  if ([self currentEditor] != nil)
  {
    [self abortEditing];
    
    // We lose focus so re-establish
    [self.window makeFirstResponder:self];
  }
}

@end

//============================================================================
@implementation MVRightFormatter

//----------------------------------------------------------------------------
- (instancetype)init
{
  NSAssert(NO, @"plain init is not allowed");
  return nil;
}

//-----------------------------------------------------------------------------
- (instancetype)initPlainWithLength:(NSUInteger)len
{
  if (self = [super init])
  {
    compound = NO;
    length = len;
    alignLeft = NO;
  }
  return self;
}

//----------------------------------------------------------------------------
- (instancetype)initLeftAlignedWithLength:(NSUInteger)len
{
  if (self = [super init])
  {
    compound = NO;
    length = len;
    alignLeft = YES;
  }
  return self;
}

//----------------------------------------------------------------------------
- (instancetype)initCompoundWithLength:(NSUInteger)len
{
  if (self = [super init])
  {
    compound = YES;
    length = len;
    alignLeft = NO;
  }
  return self;
}

//----------------------------------------------------------------------------
+ (MVRightFormatter *)plainFormatterWithLength:(NSUInteger)len
{
  return [[MVRightFormatter alloc] initPlainWithLength:len];
}

//----------------------------------------------------------------------------
+ (MVRightFormatter *)leftAlignedFormatterWithLength:(NSUInteger)len
{
  return [[MVRightFormatter alloc] initLeftAlignedWithLength:len];
}

//----------------------------------------------------------------------------
+ (MVRightFormatter *)compoundFormatterWithLength:(NSUInteger)len
{
  return [[MVRightFormatter alloc] initCompoundWithLength:len];
}

//----------------------------------------------------------------------------
- (NSString *)stringForObjectValue:(id)anObject
{
  if ([anObject isKindOfClass:[NSAttributedString class]])
  {
    return [anObject string]; 
  }
  return anObject;
}

//----------------------------------------------------------------------------
- (BOOL)getObjectValue:(id *)anObject 
             forString:(NSString *)string 
      errorDescription:(NSString **)error
{
  if (compound)
  {
    (*anObject) = string;
  } 
  else
  {
    // put leading zeroes in order to preserve the original length
    if (string.length > length) return NO;
    NSUInteger numZeroes = length - string.length;
    NSMutableString * zeroes = [[NSMutableString alloc] initWithCapacity:numZeroes];
    while (numZeroes-- > 0)
    {
      [zeroes appendString:@"0"];
    }
    (*anObject) = [NSString  stringWithFormat:@"%@%@", 
                   alignLeft ? string : zeroes, 
                   alignLeft ? zeroes : string];
  }

  return YES;
}

//----------------------------------------------------------------------------
- (NSAttributedString *)attributedStringForObjectValue:(id)anObject 
                                 withDefaultAttributes:(NSDictionary *)attributes
{
  if ([anObject isKindOfClass:[NSAttributedString class]])
  {
    return anObject;
  }
  return nil;
}

//----------------------------------------------------------------------------
- (BOOL)isPartialStringValid:(NSString **)partialStringPtr 
       proposedSelectedRange:(NSRangePointer)proposedSelRangePtr 
              originalString:(NSString *)origString 
       originalSelectedRange:(NSRange)origSelRange 
            errorDescription:(NSString **)error
{
  NSScanner * scanner = [NSScanner scannerWithString:*partialStringPtr];

  if (compound)
  // option 1: formatted hex value (11 22 33 44 55 66 77 88 )
  {
    scanner.charactersToBeSkipped = [NSCharacterSet whitespaceCharacterSet];
    
    NSUInteger numBytes = length;
    while (scanner.atEnd == NO)
    {
      unsigned value;
      
      // value needs to be hex and number of bytes is determined
      if ([scanner scanHexInt:&value] == NO || value > 0xff || numBytes == 0)
      {
        return NO;
      }

      --numBytes;
    }
    
  }
  else
  // option 2: plain hex value
  {
    [scanner setCharactersToBeSkipped:nil];
    
    NSCharacterSet * characterSet = [NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDEFabcdef"];
    while (scanner.atEnd == NO)
    {
      // must be a valid hex value
      if ([scanner scanCharactersFromSet:characterSet intoString:NULL] == NO)
      {
        return NO;
      }
      
      // apply upper limit on length
      if ((*partialStringPtr).length > length)
      {
        return NO;
      }
    }
  }
  
  return YES;
}


@end

//============================================================================
@implementation MVDocument

@synthesize dataController;

enum ViewType
{    
  e_details,
  e_details64,
  e_hex,
  e_hex64,
};

//----------------------------------------------------------------------------
+ (NSString *)temporaryDirectory
{
  static NSString * directory;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSString * name = [@"MachOView-" stringByAppendingString:[NSUUID UUID].UUIDString];
    NSString * path = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
    NSError * error = nil;
    if ([[NSFileManager defaultManager] createDirectoryAtPath:path
                               withIntermediateDirectories:NO
                                                attributes:@{NSFilePosixPermissions: @0700}
                                                     error:&error])
      directory = path;
    else
      NSLog(@"Cannot create temporary directory: %@", error);
  });
  return directory;
}

//-----------------------------------------------------------------------------
- (instancetype)init
{
  self = [super init];
  if (self) 
  {
    dataController = [[MVDataController alloc] init];
    threadCount = 0;
    notificationLock = [[NSLock alloc] init];
    pendingTreeNodes = [[NSMutableSet alloc] init];

    NSNotificationCenter * nc = [NSNotificationCenter defaultCenter];
    typeof(self) __weak weakSelf = self;
    
    /*
    [nc addObserver:weakSelf
           selector:@selector(handleDataTreeWillChange:) 
               name:MVDataTreeWillChangeNotification
             object:nil]; 
    
    [nc addObserver:weakSelf
           selector:@selector(handleDataTreeDidChange:) 
               name:MVDataTreeDidChangeNotification
             object:nil]; 
    */
    [nc addObserver:weakSelf
           selector:@selector(handleDataTreeChanged:) 
               name:MVDataTreeChangedNotification
             object:nil]; 
    
    [nc addObserver:weakSelf
           selector:@selector(handleDataTableChanged:) 
               name:MVDataTableChangedNotification
             object:nil]; 

    [nc addObserver:weakSelf 
           selector:@selector(handleThreadStateChanged:) 
               name:MVThreadStateChangedNotification
             object:nil];
  }
  return self;
}

//----------------------------------------------------------------------------
- (NSString *)windowNibName 
{
  // Implement this to return a nib to load OR implement -makeWindowControllers to manually create your controllers.
  return @"Layout";
}

//----------------------------------------------------------------------------
- (BOOL)isRVA
{
  return (offsetModeSwitch.selectedSegment == 1 ? YES : NO);
}

//----------------------------------------------------------------------------
- (void)handleDataTreeWillChange:(NSNotification *)notification
{
  if (notification.object == dataController)
  {
    // lock treeView
  }
}

//----------------------------------------------------------------------------
- (void)handleDataTreeDidChange:(NSNotification *)notification
{
  if (notification.object == dataController)
  {
    // unlock treeView
  }
}

//----------------------------------------------------------------------------
- (void)handleDataTreeChanged:(NSNotification *)notification
{
  if (notification.object != dataController) return;
  [notificationLock lock];
  MVNode * node = notification.userInfo[MVNodeUserInfoKey];
  if (node == nil || pendingTreeNodes.count >= 256)
  {
    fullTreeRefreshPending = YES;
    [pendingTreeNodes removeAllObjects];
  }
  else if (!fullTreeRefreshPending)
    [pendingTreeNodes addObject:node];
  BOOL schedule = !treeRefreshPending;
  treeRefreshPending = YES;
  [notificationLock unlock];
  if (!schedule) return;

  __weak MVDocument * weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    MVDocument * document = weakSelf;
    if (document == nil) return;
    [document->notificationLock lock];
    NSArray * nodes = document->pendingTreeNodes.allObjects;
    BOOL full = document->fullTreeRefreshPending;
    [document->pendingTreeNodes removeAllObjects];
    document->treeRefreshPending = NO;
    document->fullTreeRefreshPending = NO;
    [document->notificationLock unlock];
    if (document->closed) return;
    if (full)
      [document->leftView reloadData];
    else
      for (MVNode * changed in nodes)
      {
        [document->leftView reloadItem:changed.parent reloadChildren:YES];
        [document->leftView reloadItem:changed];
      }
  });
}

//----------------------------------------------------------------------------
- (void)handleDataTableChanged:(NSNotification *)notification
{
  if (notification.object != dataController) return;
  [notificationLock lock];
  BOOL schedule = !tableRefreshPending;
  tableRefreshPending = YES;
  [notificationLock unlock];
  if (!schedule) return;
  __weak MVDocument * weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    MVDocument * document = weakSelf;
    if (document == nil) return;
    [document->notificationLock lock];
    document->tableRefreshPending = NO;
    [document->notificationLock unlock];
    if (document->closed) return;
    [document.dataController.selectedNode filterDetails:document->searchField.stringValue];
    [document->rightView noteNumberOfRowsChanged];
    [document->rightView reloadData];
  });
}

//----------------------------------------------------------------------------
- (void)handleThreadStateChanged:(NSNotification *)notification
{
  if (notification.object != dataController) return;
  NSString * state = notification.userInfo[MVStatusUserInfoKey];
  [notificationLock lock];
  if ([state isEqualToString:MVStatusTaskStarted]) ++threadCount;
  else if ([state isEqualToString:MVStatusTaskTerminated] && threadCount > 0) --threadCount;
  BOOL schedule = !statusRefreshPending;
  statusRefreshPending = YES;
  [notificationLock unlock];
  if (!schedule) return;
  __weak MVDocument * weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    MVDocument * document = weakSelf;
    if (document == nil) return;
    [document->notificationLock lock];
    BOOL active = document->threadCount > 0;
    document->statusRefreshPending = NO;
    [document->notificationLock unlock];
    if (document->closed) return;
    if (active) [document->progressIndicator startAnimation:nil];
    else
    {
      [document->progressIndicator stopAnimation:nil];
      document->statusText.stringValue = @"";
    }
    [document->stopButton setHidden:!active];
  });
}

//----------------------------------------------------------------------------
- (void)windowControllerDidLoadNib:(NSWindowController *)aController
{
  [super windowControllerDidLoadNib:aController];
  
  // fill in initial data sources
  statusText.stringValue = @"Loading...";
  for (MVLayout * layout in dataController.layouts)
  {
    // Malformed or unexpected load commands raise; never let that escape into
    // AppKit while the window is being set up. Show what was parsed so far.
    @try
    {
      [layout doMainTasks];
    }
    @catch (NSException * exception)
    {
      [layout printException:exception caption:@"Main processing"];
    }
  }
  
  // refresh initial view
  [leftView reloadData];
  [leftView expandItem:dataController.rootNode];
  
  // finish processing in background
  statusText.stringValue = @"Processing in background...";
  for (MVLayout * layout in dataController.layouts)
  {
#ifdef MV_NO_MULTITHREAD
    [layout doBackgroundTasks];
#else
    [layout startBackgroundTasks];
#endif
  }
}

//----------------------------------------------------------------------------
- (void)awakeFromNib
{
  rightView.doubleAction = @selector(rightViewDoubleAction:);
  rightView.target = self;
}

//----------------------------------------------------------------------------
- (NSData *)dataOfType:(NSString *)typeName error:(NSError **)outError
{
  return dataController.fileData;
}

//----------------------------------------------------------------------------
- (BOOL)readFromURL:(NSURL *)absoluteURL ofType:(NSString *)typeName error:(NSError **)outError
{
  dataController.fileName = absoluteURL.path;
  dataController.fileData = [NSMutableData dataWithContentsOfURL:absoluteURL
                                                        options:NSDataReadingMappedIfSafe
                                                          error:outError];
  if (dataController.fileData == nil) return NO;
  // Independent mutable relocation/binding view, without copying the entire
  // binary to a temporary file and reading it a second time.
  dataController.realData = [dataController.fileData mutableCopy];
  @try
  {
    [dataController createLayouts:dataController.rootNode location:0 length:dataController.fileData.length];
  }
  @catch (NSException * exception)
  {
    if (outError != NULL)
      *outError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadUnknownError
                                  userInfo:@{NSFilePathErrorKey: absoluteURL.path ?: @"",
                                            NSLocalizedDescriptionKey: exception.reason ?: @"Invalid binary"}];
    return NO;
  }
  return YES;
}

//----------------------------------------------------------------------------
- (void)saveDocumentWithDelegate:(id)delegate didSaveSelector:(SEL)didSaveSelector contextInfo:(void *)contextInfo
{
  if (delegate != nil)
  {
    [self runModalSavePanelForSaveOperation:NSSaveAsOperation
                                   delegate:delegate 
                            didSaveSelector:didSaveSelector 
                                contextInfo:contextInfo];
  }
  else
  {
    [super saveDocumentWithDelegate:delegate 
                    didSaveSelector:didSaveSelector
                        contextInfo:contextInfo];
  }
}

//----------------------------------------------------------------------------
- (IBAction)updateSearchFilter:(id)sender
{
  NSString * filter = searchField.stringValue;
  if (dataController.selectedNode.details != nil)
  {
    [dataController.selectedNode filterDetails:filter];
    [rightView reloadData];
  }
}

//----------------------------------------------------------------------------
- (IBAction)updateAddressingMode:(id)sender
{
  // send notification as if the tree has changed
  NSNotificationCenter * nc = [NSNotificationCenter defaultCenter];
  [nc postNotificationName:NSOutlineViewSelectionDidChangeNotification
                    object:leftView];
}

//----------------------------------------------------------------------------
- (IBAction)stopProcessing:(id)sender
{
  // stopping threads takes time so disable the stop button to give a feedback
  // and preserve from further clicks
  [stopButton setEnabled:NO];
  
  // stop every background task
  for (MVLayout * layout in dataController.layouts)
  {
    [layout.backgroundThread cancel];
  }
}

//----------------------------------------------------------------------------
- (IBAction)rightViewDoubleAction:(id)sender 
{
  NSParameterAssert(sender == rightView);
           
  NSInteger colIndex = [sender clickedColumn];
  NSInteger rowIndex = [sender clickedRow];
  if (rowIndex < 0 || colIndex < 0 || (NSUInteger)colIndex >= rightView.tableColumns.count) return;

  if (rightView.tableColumns[colIndex].editable)
  {
    if (dataController.selectedNode.details != nil)
    {
      MVRow * row = [dataController.selectedNode.details getRowToDisplay:rowIndex];
      if (row == nil)
      {
        return;
      }
      
      NSString * cellContent = [row coloumnAtIndex:colIndex];
      if (cellContent.length == 0)
      {
        return;
      }
    }
    [rightView editColumn:colIndex row:rowIndex withEvent:nil select:YES];
    return;
  }
  
  
  // jump to symbol definition
  if (colIndex == VALUE_COLUMN)
  {
    // determine symbol type (local, public, external)
  
    //NSIndexSet * indexes;
    //[leftView selectRowIndexes:indexes byExtendingSelection:NO];
  }
}

//----------------------------------------------------------------------------
- (void)changeView:(ViewType)viewType
{
  //get current values
  NSTableColumn * column0 = rightView.tableColumns[0];
  NSTableColumn * column1 = rightView.tableColumns[1];
  NSTableColumn * column2 = rightView.tableColumns[2];
  NSTableColumn * column3 = rightView.tableColumns[3];
  
  switch (viewType)
  {
    case e_details:       
    case e_details64:
      column0.headerCell.stringValue = self.isRVA == NO ? @"Offset" : @"Address";
      column1.headerCell.stringValue = @"Data";
      column2.headerCell.stringValue = @"Description";
      column3.headerCell.stringValue = @"Value"; 
      
      [column0 setEditable:NO];
      [column1 setEditable:YES];
      [column2 setEditable:NO];
      [column3 setEditable:NO];
      break;
      
    case e_hex:
    case e_hex64:
      column0.headerCell.stringValue = self.isRVA == NO ? @"pFile" : @"Address";
      column1.headerCell.stringValue = @"Data LO";
      column2.headerCell.stringValue = @"Data HI";
      column3.headerCell.stringValue = @"Value";
      
      [column0 setEditable:NO];
      [column1 setEditable:YES];
      [column2 setEditable:YES];
      [column3 setEditable:NO];      
      break;
      
    default:; // do not change current view
  }
}

//----------------------------------------------------------------------------
- (void)close
{
  // Cancelling a Save/Don't Save/Cancel sheet must not stop a still-open document.
  closed = YES;
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  for (MVLayout * layout in dataController.layouts) [layout.backgroundThread cancel];
  [dataController.selectedNode closeDetails];
  [super close];
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}


#pragma mark responders for UI events

//----------------------------------------------------------------------------
- (void)outlineViewSelectionDidChange:(NSNotification *)notification
{
  if (notification.object == leftView)
  {
    NSInteger rowIndex = leftView.selectedRow;
    MVNode * nodeToSelect = [leftView itemAtRow:rowIndex];
    
    if (dataController.selectedNode != nodeToSelect)
    {
      [dataController.selectedNode closeDetails];
      // Publish selection BEFORE opening/filtering, so the writer cannot evict
      // the newly selected table between those operations.
      dataController.selectedNode = nodeToSelect;
      [nodeToSelect openDetails];
      searchField.stringValue = @"";
      [nodeToSelect filterDetails:nil];
    }
  
    MVLayout * layout = (nodeToSelect.userInfo)[MVLayoutUserInfoKey];
    BOOL is64bit = [layout is64bit];
  
    if (nodeToSelect.details != nil)
    {
      [self changeView:is64bit == NO ? e_details : e_details64];
    }
    else 
    {
      [self changeView:is64bit == NO ? e_hex : e_hex64];
    }
    
    [rightView reloadData];
  }
}

//----------------------------------------------------------------------------
// set up the formatter for editable cells
//----------------------------------------------------------------------------
- (void)tableView:(NSTableView *)aTableView 
  willDisplayCell:(id)aCell 
   forTableColumn:(NSTableColumn *)aTableColumn 
              row:(NSInteger)rowIndex
{
  if (aTableView == rightView)
  {
    if (dataController.selectedNode.details != nil)
    {
      MVRow * row = [dataController.selectedNode.details getRowToDisplay:rowIndex];
      if (row == nil)
      {
        return;
      }
      
      NSUInteger len = (row.coloumns.dataStr).length;
      
      [aCell setFormatter:len > 16
       ? [MVRightFormatter leftAlignedFormatterWithLength:len] 
       : [MVRightFormatter plainFormatterWithLength:len]];
    }
    else
    {
      NSUInteger colIndex = [aTableView.tableColumns indexOfObject:aTableColumn];
      NSUInteger len = MIN(dataController.selectedNode.dataRange.length - rowIndex * 16, (NSUInteger)16);
      
      if (colIndex == DATA_LO_COLUMN)
      {
        [aCell setFormatter:[MVRightFormatter compoundFormatterWithLength:len > 8 ? 8 : len]];
      }
      else if (colIndex == DATA_HI_COLUMN)
      {
        [aCell setFormatter:[MVRightFormatter compoundFormatterWithLength:len > 8 ? len - 8 : 0]];
      }
    }
  }
}

//----------------------------------------------------------------------------
// TODO: show different tooltips for each if the cell contains more then one symbol
//----------------------------------------------------------------------------
- (NSString *)tableView:(NSTableView *)aTableView 
         toolTipForCell:(NSCell *)aCell 
                   rect:(NSRectPointer)rect 
            tableColumn:(NSTableColumn *)aTableColumn 
                    row:(NSInteger)rowIndex 
          mouseLocation:(NSPoint)mouseLocation
{
  if (aTableView == rightView)
  {
    MVRow * row = [dataController.selectedNode.details getRowToDisplay:rowIndex];
    if (row == nil)
    {
      return nil;
    }
      
    NSUInteger colIndex = [aTableView.tableColumns indexOfObject:aTableColumn];
    NSString * cellContent = [row coloumnAtIndex:colIndex];
    
    // try to find C,C++ symbol prologue
    NSUInteger start = [cellContent rangeOfString:@"_Z"].location;

    if (start == NSNotFound)
    {
      return nil;
    }

    NSUInteger stop = [cellContent rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@")]"]
                                                   options:NSLiteralSearch
                                                     range:NSMakeRange(start, cellContent.length - start)].location;
    if (stop == NSNotFound)
    {
      stop = cellContent.length;
    }
    
    char const * cell_str = CSTRING([cellContent substringWithRange:NSMakeRange(start, stop - start)]);

    int status;
    char * sym_str = abi::__cxa_demangle (cell_str, NULL, NULL, &status);
    if (status == 0)
    {
      NSString * toolTip= NSSTRING(sym_str);
      free(sym_str);
      return toolTip;
    }
  }
  
  return nil;
}


@end
