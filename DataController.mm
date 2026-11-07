/*
 *  DataController.mm
 *  MachOView
 *
 *  Created by Bugra Karabudak on 15/06/2010.
 *
 */

#import "Common.h"
#import "DataController.h"
#import "MachOLayout.h"
#import "FatLayout.h"
#import "ArchiveLayout.h"
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

// All access to an archiver's live rows, indexes and reader streams shares this
// lock. A serial writer queue alone cannot protect rows mutated by parser/UI threads.
class MVArchiveGuard
{
  MVArchiver * archiver;
public:
  explicit MVArchiveGuard(MVArchiver * value) : archiver(value) { [archiver suspend]; }
  ~MVArchiveGuard() { [archiver resume]; }
  MVArchiveGuard(const MVArchiveGuard &) = delete;
  MVArchiveGuard & operator=(const MVArchiveGuard &) = delete;
};

static void MVWrite(const void * bytes, size_t size, size_t count, FILE * file)
{
  if (file == NULL || fwrite(bytes, size, count, file) != count)
    [NSException raise:@"MVSwapFileError" format:@"Cannot write swap file: %s", strerror(errno)];
}

static void MVRead(void * bytes, size_t size, size_t count, FILE * file)
{
  if (file == NULL || fread(bytes, size, count, file) != count)
    [NSException raise:@"MVSwapFileError" format:@"Truncated or unreadable swap file"];
}

static void MVSeek(FILE * file, uint64_t offset)
{
  if (file == NULL || offset > INT64_MAX || fseeko(file, (off_t)offset, SEEK_SET) != 0)
    [NSException raise:@"MVSwapFileError" format:@"Cannot seek swap file"];
}

static uint64_t MVPosition(FILE * file)
{
  off_t position = ftello(file);
  if (position < 0)
    [NSException raise:@"MVSwapFileError" format:@"Cannot get swap file position"];
  return (uint64_t)position;
}

enum {
  MVUnderlineAttributeOrdinal = 1,
  MVCellColorAttributeOrdinal,
  MVTextColorAttributeOrdinal,
  MVMetaDataAttributeOrdinal
};

enum {
  MVBlackColorOrdinal = 1,
  MVDarkGrayColorOrdinal,
  MVLightGrayColorOrdinal,
  MVWhiteColorOrdinal,
  MVGrayColorOrdinal,
  MVRedColorOrdinal,
  MVGreenColorOrdinal,
  MVBlueColorOrdinal,
  MVCyanColorOrdinal,
  MVYellowColorOrdinal,
  MVMagentaColorOrdinal,
  MVOrangeColorOrdinal,
  MVPurpleColorOrdinal,
  MVBrownColorOrdinal
};

NSString * const MVUnderlineAttributeName         = @"MVUnderlineAttribute";
NSString * const MVCellColorAttributeName         = @"MVCellColorAttribute";
NSString * const MVTextColorAttributeName         = @"MVTextColorAttribute";
NSString * const MVMetaDataAttributeName          = @"MVMetaDataAttribute";

NSString * const MVLayoutUserInfoKey              = @"MVLayoutUserInfoKey";
NSString * const MVNodeUserInfoKey                = @"MVNodeUserInfoKey";
NSString * const MVStatusUserInfoKey              = @"MVStatusUserInfoKey";

NSString * const MVDataTreeWillChangeNotification = @"MVDataTreeWillChangeNotification";
NSString * const MVDataTreeDidChangeNotification  = @"MVDataTreeDidChangeNotification";
NSString * const MVDataTreeChangedNotification    = @"MVDataTreeChanged";
NSString * const MVDataTableChangedNotification   = @"MVDataTableChanged";
NSString * const MVThreadStateChangedNotification = @"MVThreadStateChanged";

NSString * const MVStatusTaskStarted              = @"MVStatusTaskStarted";
NSString * const MVStatusTaskTerminated           = @"MVStatusTaskTerminated";

//============================================================================
@implementation MVColoumns

@synthesize offsetStr, dataStr, descriptionStr, valueStr; 

//-----------------------------------------------------------------------------
- (instancetype)init 
{
  self = [super init];
  if (self)
  {
#ifdef MV_STATISTICS
    __atomic_fetch_add(&nrow_loaded, 1, __ATOMIC_RELAXED);
#endif
  }
  return self;
}

//-----------------------------------------------------------------------------
-(instancetype)initWithData:(NSString *)col0 :(NSString *)col1 :(NSString *)col2 :(NSString *)col3
{
  if (self = [super init])
  {
    offsetStr = [col0 copy];
    dataStr = [col1 copy];
    descriptionStr = [col2 copy];
    valueStr = [col3 copy];
    
#ifdef MV_STATISTICS
    __atomic_fetch_add(&nrow_loaded, 1, __ATOMIC_RELAXED);
#endif
  }
  return self;
}

//-----------------------------------------------------------------------------
+(MVColoumns *) coloumnsWithData:(NSString *)col0 :(NSString *)col1 :(NSString *)col2 :(NSString *)col3
{
  return [[MVColoumns alloc] initWithData:col0:col1:col2:col3];
}

//-----------------------------------------------------------------------------
-(void)dealloc
{
#ifdef MV_STATISTICS
  __atomic_fetch_sub(&nrow_loaded, 1, __ATOMIC_RELAXED);
#endif
}

@end


//============================================================================
@implementation MVRow

@synthesize coloumns, attributes, offset, deleted, dirty;

//-----------------------------------------------------------------------------
- (instancetype)init 
{
  self = [super init];
  if (self)
  {
#ifdef MV_STATISTICS
    __atomic_fetch_add(&nrow_total, 1, __ATOMIC_RELAXED);
#endif
  }
  return self;
}

//-----------------------------------------------------------------------------
-(void)dealloc
{
#ifdef MV_STATISTICS  
  __atomic_fetch_sub(&nrow_total, 1, __ATOMIC_RELAXED);
#endif
}

//-----------------------------------------------------------------------------
-(NSString *)coloumnAtIndex:(NSUInteger)index
{
  switch (index)
  {
    case OFFSET_COLUMN:       return coloumns.offsetStr;
    case DATA_COLUMN:         return coloumns.dataStr;    
    case DESCRIPTION_COLUMN:  return coloumns.descriptionStr;
    case VALUE_COLUMN:        return coloumns.valueStr;
  }
  return nil;
}

//-----------------------------------------------------------------------------
-(void)replaceColoumnAtIndex:(NSUInteger)index withString:(NSString *)str
{
  coloumnsOffset = 0;
  
  
  switch (index)
  {
    case OFFSET_COLUMN:       coloumns.offsetStr = str; break;
    case DATA_COLUMN:         coloumns.dataStr = str;  break;
    case DESCRIPTION_COLUMN:  coloumns.descriptionStr = str; break;
    case VALUE_COLUMN:        coloumns.valueStr = str; break;
  }
}

//-----------------------------------------------------------------------------
- (void)writeString:(NSString *)str toFile:(FILE *)pFile
{
  // NSString.length counts UTF-16 code units, NOT the bytes written to disk.
  NSData * data = [(str ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
  uint64_t length = data.length;
  MVWrite(&length, sizeof(length), 1, pFile);
  if (length != 0) MVWrite(data.bytes, 1, (size_t)length, pFile);
}

//-----------------------------------------------------------------------------
- (NSString *)readStringFromFile:(FILE *)pFile
{
  uint64_t length = 0;
  MVRead(&length, sizeof(length), 1, pFile);
  // Check the remaining file size before allocating from a stored length.
  off_t start = ftello(pFile);
  struct stat info;
  if (start < 0 || fstat(fileno(pFile), &info) != 0 || info.st_size < start ||
      length > (uint64_t)(info.st_size - start) || length > NSUIntegerMax)
    [NSException raise:@"MVSwapFileError" format:@"Invalid swap string length"];
  NSMutableData * data = [NSMutableData dataWithLength:(NSUInteger)length];
  if (length != 0) MVRead(data.mutableBytes, 1, (size_t)length, pFile);
  NSString * string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  if (string == nil)
    [NSException raise:@"MVSwapFileError" format:@"Invalid UTF-8 in swap file"];
  return string;
}

//-----------------------------------------------------------------------------
- (void)writeColor:(NSColor *)color toFile:(FILE *)pFile
{
  int colorOrdinal = [color isEqualTo:[NSColor blackColor]]     ? MVBlackColorOrdinal
                   : [color isEqualTo:[NSColor darkGrayColor]]  ? MVDarkGrayColorOrdinal
                   : [color isEqualTo:[NSColor lightGrayColor]] ? MVLightGrayColorOrdinal
                   : [color isEqualTo:[NSColor whiteColor]]     ? MVWhiteColorOrdinal
                   : [color isEqualTo:[NSColor grayColor]]      ? MVGrayColorOrdinal
                   : [color isEqualTo:[NSColor redColor]]       ? MVRedColorOrdinal
                   : [color isEqualTo:[NSColor greenColor]]     ? MVGreenColorOrdinal
                   : [color isEqualTo:[NSColor blueColor]]      ? MVBlueColorOrdinal
                   : [color isEqualTo:[NSColor cyanColor]]      ? MVCyanColorOrdinal
                   : [color isEqualTo:[NSColor yellowColor]]    ? MVYellowColorOrdinal
                   : [color isEqualTo:[NSColor magentaColor]]   ? MVMagentaColorOrdinal
                   : [color isEqualTo:[NSColor orangeColor]]    ? MVOrangeColorOrdinal
                   : [color isEqualTo:[NSColor purpleColor]]    ? MVPurpleColorOrdinal
                   : [color isEqualTo:[NSColor brownColor]]     ? MVBrownColorOrdinal
                   : 0;
  
  uint8_t ordinal = (uint8_t)colorOrdinal;
  MVWrite(&ordinal, sizeof(ordinal), 1, pFile);
  if (colorOrdinal == 0)
  {
    CGFloat red, green, blue, alpha;
    [color getRed:&red green:&green blue:&blue alpha:&alpha];
    float fred = red, fgreen = green, fblue = blue, falpha = alpha;
    MVWrite(&fred, sizeof(float), 1, pFile);
    MVWrite(&fgreen, sizeof(float), 1, pFile);
    MVWrite(&fblue, sizeof(float), 1, pFile);
    MVWrite(&falpha, sizeof(float), 1, pFile);
  }
}

//-----------------------------------------------------------------------------
- (NSColor *)readColorFromFile:(FILE *)pFile
{
  uint8_t colorOrdinal;
  MVRead(&colorOrdinal, sizeof(colorOrdinal), 1, pFile);
  if (colorOrdinal > MVBrownColorOrdinal)
    [NSException raise:@"MVSwapFileError" format:@"Invalid swap color"];
  switch (colorOrdinal)
  {
    case MVBlackColorOrdinal:     return [NSColor blackColor];
    case MVDarkGrayColorOrdinal:  return [NSColor darkGrayColor];
    case MVLightGrayColorOrdinal: return [NSColor lightGrayColor];
    case MVWhiteColorOrdinal:     return [NSColor whiteColor];
    case MVGrayColorOrdinal:      return [NSColor grayColor];
    case MVRedColorOrdinal:       return [NSColor redColor];
    case MVGreenColorOrdinal:     return [NSColor greenColor];
    case MVBlueColorOrdinal:      return [NSColor blueColor];
    case MVCyanColorOrdinal:      return [NSColor cyanColor];
    case MVYellowColorOrdinal:    return [NSColor yellowColor];
    case MVMagentaColorOrdinal:   return [NSColor magentaColor];
    case MVOrangeColorOrdinal:    return [NSColor orangeColor];
    case MVPurpleColorOrdinal:    return [NSColor purpleColor];
    case MVBrownColorOrdinal:     return [NSColor brownColor];
  }

  float fred, fgreen, fblue, falpha;
  MVRead(&fred, sizeof(float), 1, pFile);
  MVRead(&fgreen, sizeof(float), 1, pFile);
  MVRead(&fblue, sizeof(float), 1, pFile);
  MVRead(&falpha, sizeof(float), 1, pFile);
  return [NSColor colorWithDeviceRed:fred green:fgreen blue:fblue alpha:falpha];
}

//----------------------------------------------------------------------------
- (void)saveAttributestoFile:(FILE *)pFile
{
  uint64_t numAttributes = attributes.count;
  MVWrite(&numAttributes, sizeof(uint64_t), 1, pFile);
  
  for (NSString * key in attributes.allKeys)
  {
    id value = attributes[key];
    if (value == nil)
    {
      continue;
    }
    
    int keyOrdinal = [key isEqualToString:MVUnderlineAttributeName] ? MVUnderlineAttributeOrdinal 
                   : [key isEqualToString:MVCellColorAttributeName] ? MVCellColorAttributeOrdinal
                   : [key isEqualToString:MVTextColorAttributeName] ? MVTextColorAttributeOrdinal
                   : [key isEqualToString:MVMetaDataAttributeName] ? MVMetaDataAttributeOrdinal
                   : 0;

    uint8_t ordinal = (uint8_t)keyOrdinal;
    MVWrite(&ordinal, sizeof(ordinal), 1, pFile);
    switch (keyOrdinal)
    {
      case MVUnderlineAttributeOrdinal: [self writeString:value toFile:pFile]; break;
      case MVCellColorAttributeOrdinal: [self writeColor:value toFile:pFile]; break;
      case MVTextColorAttributeOrdinal: [self writeColor:value toFile:pFile]; break;
      case MVMetaDataAttributeOrdinal:  [self writeString:value toFile:pFile]; break;
      default: [NSException raise:@"MVSwapFileError" format:@"Unknown swap attribute key"];
    }
  }
}

//----------------------------------------------------------------------------
- (void)loadAttributesFromFile:(FILE *)pFile
{
  uint64_t numAttributes;
  MVRead(&numAttributes, sizeof(uint64_t), 1, pFile);
  if (numAttributes > 4)
    [NSException raise:@"MVSwapFileError" format:@"Invalid swap attribute count"];
  
  NSMutableDictionary * _attributes = [[NSMutableDictionary alloc] initWithCapacity:numAttributes];
  while (numAttributes-- > 0)
  {
    uint8_t keyOrdinal;
    MVRead(&keyOrdinal, sizeof(keyOrdinal), 1, pFile);
    switch (keyOrdinal)
    {
      case MVUnderlineAttributeOrdinal: _attributes[MVUnderlineAttributeName] = [self readStringFromFile:pFile]; break;
      case MVCellColorAttributeOrdinal: _attributes[MVCellColorAttributeName] = [self readColorFromFile:pFile]; break;
      case MVTextColorAttributeOrdinal: _attributes[MVTextColorAttributeName] = [self readColorFromFile:pFile]; break;
      case MVMetaDataAttributeOrdinal:  _attributes[MVMetaDataAttributeName] = [self readStringFromFile:pFile]; break;
      default: [NSException raise:@"MVSwapFileError" format:@"Unknown swap attribute key"];
    }
  }
  
  attributes = _attributes;
}

//----------------------------------------------------------------------------
- (void)saveToFile:(FILE *)pFile
{
  if (coloumnsOffset == 0)
  {
    uint64_t filePos = MVPosition(pFile);
    [self writeString:coloumns.offsetStr toFile:pFile];
    [self writeString:coloumns.dataStr toFile:pFile];
    [self writeString:coloumns.descriptionStr toFile:pFile];
    [self writeString:coloumns.valueStr toFile:pFile];
    coloumnsOffset = filePos;
  }

  if (dirty)
  {
    if (attributesOffset > 0)
    {
      NSDictionary * changes = attributes;
      uint64_t appendPosition = MVPosition(pFile);
      MVSeek(pFile, attributesOffset);
      [self loadAttributesFromFile:pFile];
      MVSeek(pFile, appendPosition);
      NSMutableDictionary * merged = [attributes mutableCopy];
      [merged addEntriesFromDictionary:changes]; // newest values win
      attributes = merged;
    }

    uint64_t filePos = MVPosition(pFile);
    [self saveAttributestoFile:pFile];
    dirty = NO;
    attributesOffset = filePos;
  }
}

//----------------------------------------------------------------------------
- (void)loadFromFile:(FILE *)pFile
{
  if (coloumns == nil)
  {
    NSParameterAssert(coloumnsOffset != 0);
    MVSeek(pFile, coloumnsOffset);
    MVColoumns * loaded = [[MVColoumns alloc] init];
    loaded.offsetStr = [self readStringFromFile:pFile];
    loaded.dataStr = [self readStringFromFile:pFile];
    loaded.descriptionStr = [self readStringFromFile:pFile];
    loaded.valueStr = [self readStringFromFile:pFile];
    coloumns = loaded;
  }
  [self loadAttributesIfNeeded:pFile];
}

- (void)loadAttributesIfNeeded:(FILE *)pFile
{
  if (attributesOffset > 0 && (attributes == nil || dirty))
  {
    NSDictionary * changes = attributes;
    MVSeek(pFile, attributesOffset);
    [self loadAttributesFromFile:pFile];
    if (dirty)
    {
      NSMutableDictionary * merged = [attributes mutableCopy];
      [merged addEntriesFromDictionary:changes];
      attributes = merged;
    }
  }
}

// UI consumers must not retain a mutable row that the writer can evict/change.
- (MVRow *)displaySnapshot
{
  MVRow * snapshot = [[MVRow alloc] init];
  snapshot.coloumns = [MVColoumns coloumnsWithData:coloumns.offsetStr :coloumns.dataStr
                                                 :coloumns.descriptionStr :coloumns.valueStr];
  snapshot.attributes = [attributes copy];
  snapshot.offset = offset;
  snapshot.deleted = deleted;
  return snapshot;
}

//----------------------------------------------------------------------------
- (void)saveIndexToFile:(FILE *)pFile
{
  MVWrite(&offset, sizeof(uint64_t), 1, pFile);
  MVWrite(&coloumnsOffset, sizeof(uint64_t), 1, pFile);
  MVWrite(&attributesOffset, sizeof(uint64_t), 1, pFile);
  MVWrite(&deleted, sizeof(BOOL), 1, pFile);
}

//----------------------------------------------------------------------------
- (void)loadIndexFromFile:(FILE *)pFile
{
  MVRead(&offset, sizeof(uint64_t), 1, pFile);
  MVRead(&coloumnsOffset, sizeof(uint64_t), 1, pFile);
  MVRead(&attributesOffset, sizeof(uint64_t), 1, pFile);
  MVRead(&deleted, sizeof(BOOL), 1, pFile);
}

//----------------------------------------------------------------------------
-(BOOL) isSaved
{
  return (coloumnsOffset > 0);
}

//----------------------------------------------------------------------------
-(void) clear
{
  if (coloumnsOffset > 0) // isSaved == YES
  {
    coloumns = nil;

    if (dirty == NO)
    {
      attributes = nil;
    }
  }
}

@end

//============================================================================
@implementation MVTable

@synthesize swapFile;

//-----------------------------------------------------------------------------
- (instancetype)init
{
  NSAssert(NO, @"plain init is not allowed");
  return nil;
}

//-----------------------------------------------------------------------------
- (instancetype)initWithArchiver:(MVArchiver *)_archiver
{
  if (self = [super init])
  {
    rows = [[NSMutableArray alloc] init];
    archiver = _archiver;
  }
  return self;
}

//----------------------------------------------------------------------------
+(MVTable *) tableWithArchiver:(MVArchiver *)_archiver
{
  return [[MVTable alloc] initWithArchiver:_archiver];
}

//----------------------------------------------------------------------------
- (void)dealloc
{
  if (swapFile != NULL) fclose(swapFile);
}

- (FILE *)reader
{
  if (swapFile == NULL)
  {
    swapFile = fopen(archiver.swapPath.fileSystemRepresentation, "rb");
    if (swapFile == NULL)
      [NSException raise:@"MVSwapFileError" format:@"Cannot open swap file for reading"];
  }
  return swapFile;
}

- (NSUInteger)rowCountToDisplay
{
  MVArchiveGuard guard(archiver);
  return displayRows.count;
}

//----------------------------------------------------------------------------
- (MVRow *)getRowToDisplay: (NSUInteger)rowIndex
{
  MVArchiveGuard guard(archiver);
  if (rowIndex >= displayRows.count) return nil;
  MVRow * row = displayRows[rowIndex];
  if (row.deleted) return nil;
  [row loadFromFile:[self reader]];
  return [row displaySnapshot];
}

//----------------------------------------------------------------------------
- (void)insertRowWithOffset:(uint64_t)offset :(id)col0 :(id)col1 :(id)col2 :(id)col3
{
  MVRow * row = [[MVRow alloc] init];
  row.coloumns = [MVColoumns coloumnsWithData:col0:col1:col2:col3];
  row.offset = offset;
  
  MVArchiveGuard guard(archiver);
  [rows addObject:row];
  [archiver addObjectToSave:row];
}

//----------------------------------------------------------------------------
- (void)appendRow:(id)col0 :(id)col1 :(id)col2 :(id)col3
{
  [self insertRowWithOffset:0 :col0:col1:col2:col3];
}

//----------------------------------------------------------------------------
- (void)updateCellContentTo:(id)object atRow:(NSUInteger)rowIndex andCol:(NSUInteger)colIndex
{
  MVArchiveGuard guard(archiver);
  MVRow * row = rows[rowIndex];
  [row loadFromFile:[self reader]];
  [row replaceColoumnAtIndex:colIndex withString:object];
  [archiver addObjectToSave:row];
}

- (void)updateDisplayedCellContentTo:(NSString *)string atRow:(NSUInteger)rowIndex andCol:(NSUInteger)colIndex
{
  MVArchiveGuard guard(archiver);
  if (rowIndex >= displayRows.count) return;
  // A filtered display index is not an index into the unfiltered rows array.
  MVRow * row = displayRows[rowIndex];
  [row loadFromFile:[self reader]];
  [row replaceColoumnAtIndex:colIndex withString:string];
  [self setAttributes:[@{MVTextColorAttributeName: [NSColor redColor]} mutableCopy] forRow:row];
  [archiver addObjectToSave:row];
}

//----------------------------------------------------------------------------
- (void)popRow
{
  MVArchiveGuard guard(archiver);
  MVRow * row = rows.lastObject;
  row.deleted = YES;
}

//----------------------------------------------------------------------------
- (NSUInteger)rowCount
{
  MVArchiveGuard guard(archiver);
  return rows.count;
}

//----------------------------------------------------------------------------
//  input are name-value pairs
//----------------------------------------------------------------------------
-(NSMutableDictionary *)attributesWithPairs:(id)firstArg :(va_list)args
{
  NSMutableDictionary * attributes = [[NSMutableDictionary alloc] init];
  
  NSString * name = nil;
  for (id arg = firstArg; arg != nil; arg = va_arg(args, id))
  {
    if (name == nil)
    {
      name = arg;
      continue;
    }
    
    attributes[name] = arg;
    name = nil;
  }
  
  return attributes;
}

//----------------------------------------------------------------------------
- (void)setAttributes:(NSMutableDictionary *)attributes forRow:(MVRow *)row
{
  NSParameterAssert(row != nil);
  
  NSMutableDictionary * merged = [NSMutableDictionary dictionaryWithDictionary:row.attributes ?: @{}];
  [merged addEntriesFromDictionary:attributes];
  row.attributes = merged;
  row.dirty = YES;
}

//----------------------------------------------------------------------------
- (void)setAttributes:(id)firstArg, ...
{
  MVArchiveGuard guard(archiver);
  va_list args;
  va_start(args, firstArg);
  NSMutableDictionary * attributes = [self attributesWithPairs:firstArg:args];
  va_end(args);

  MVRow * row = rows.lastObject;
  [self setAttributes:attributes forRow:row];

  // update saved
  [archiver addObjectToSave:row];
}

//----------------------------------------------------------------------------
- (void)setAttributesForRowIndex:(NSUInteger)index :(id)firstArg, ...
{
  MVArchiveGuard guard(archiver);
  va_list args;
  va_start(args, firstArg);
  NSMutableDictionary * attributes = [self attributesWithPairs:firstArg:args];
  va_end(args);
  
  MVRow * row = rows[index];
  [self setAttributes:attributes forRow:row];

  // update saved
  [archiver addObjectToSave:row];
}

//----------------------------------------------------------------------------
- (void)setAttributesFromRowIndex:(NSUInteger)index :(id)firstArg, ...
{
  MVArchiveGuard guard(archiver);
  va_list args;
  va_start(args, firstArg);
  NSDictionary * attributes = [self attributesWithPairs:firstArg:args];
  va_end(args);

  for (NSUInteger numRows = rows.count; index < numRows; ++index)
  {
    MVRow * row = rows[index];
    [self setAttributes:[NSMutableDictionary dictionaryWithDictionary:attributes] forRow:row];

    // update saved
    [archiver addObjectToSave:row];
  }
}

//----------------------------------------------------------------------------
- (void) applyFilter: (NSString *)filter
{
  MVArchiveGuard guard(archiver);
  if (filter.length == 0)
  {
    displayRows = [rows mutableCopy];
    return;
  }

  NSMutableArray * matches = [[NSMutableArray alloc] init];
  FILE * reader = [self reader];
  for (MVRow * row in rows)
  {
    @autoreleasepool
    {
      // Filtering needs metadata only: don't materialize every column in a huge table.
      BOOL wasUnloaded = row.coloumns == nil;
      [row loadAttributesIfNeeded:reader];
      NSString * metadata = row.attributes[MVMetaDataAttributeName];
      if (metadata == nil || [metadata rangeOfString:filter
                        options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location != NSNotFound)
        [matches addObject:row];
      if (wasUnloaded) [row clear];
    }
  }
  displayRows = matches;
}

//----------------------------------------------------------------------------
- (void)sortByOffset
{
  MVArchiveGuard guard(archiver);
  [rows sortWithOptions:NSSortStable usingComparator:^(id obj1, id obj2)   
   {
     MVRow * row1 = obj1;
     MVRow * row2 = obj2;
     if (row1.offset < row2.offset) return (NSComparisonResult)NSOrderedAscending;
     if (row1.offset > row2.offset) return (NSComparisonResult)NSOrderedDescending;
     return (NSComparisonResult)NSOrderedSame;
   }];
}

//----------------------------------------------------------------------------
- (uint64_t)saveIndexesToFile:(FILE *)writer
{
  MVArchiveGuard guard(archiver);
  // Node and row enqueue order can differ after editing/deduplication. Ensure
  // every index references its latest data before publishing the index offset.
  for (MVRow * row in rows) [row saveToFile:writer];
  uint64_t position = MVPosition(writer);
  uint64_t count = rows.count;
  MVWrite(&count, sizeof(count), 1, writer);
  for (MVRow * row in rows) [row saveIndexToFile:writer];
  return position;
}

//----------------------------------------------------------------------------
- (void)loadIndexesFromFile:(FILE *)reader
{
  MVArchiveGuard guard(archiver);
  uint64_t count;
  MVRead(&count, sizeof(count), 1, reader);
  struct stat info;
  off_t position = ftello(reader);
  const size_t indexSize = 3 * sizeof(uint64_t) + sizeof(BOOL);
  if (position < 0 || fstat(fileno(reader), &info) != 0 || info.st_size < position ||
      count > (uint64_t)(info.st_size - position) / indexSize)
    [NSException raise:@"MVSwapFileError" format:@"Invalid swap row count"];
  while (count-- > 0)
  {
    MVRow * row = [[MVRow alloc] init];
    [row loadIndexFromFile:reader];
    [rows addObject:row];
  }
}

@end


//============================================================================
@implementation MVNode

@synthesize caption, parent, dataRange, details, userInfo, detailsOffset;

//-----------------------------------------------------------------------------
-(instancetype)init
{
  if (self = [super init]) 
  {
    children = [[NSMutableArray alloc] init];
    userInfo = [[NSMutableDictionary alloc] init];
  }
  return self;
}

//----------------------------------------------------------------------------
-(NSString *)description
{
  return [super.description stringByAppendingFormat:@" [%@]", caption];
}

//----------------------------------------------------------------------------
- (MVNode *)childAtIndex:(NSUInteger)n 
{
  @synchronized(children) { return n < children.count ? children[n] : nil; }
}

//----------------------------------------------------------------------------
- (NSUInteger)numberOfChildren 
{
  @synchronized(children) { return children.count; }
}

//----------------------------------------------------------------------------
- (void)insertNode:(MVNode *)node
{
  MVLayout * layout = userInfo[MVLayoutUserInfoKey];
  
  [layout.dataController.treeLock lock];
  
  NSNotificationCenter * nc = [NSNotificationCenter defaultCenter];
  [nc postNotificationName:MVDataTreeWillChangeNotification object:layout.dataController];
  @synchronized(children)
  {
    // Upper bound preserves insertion order for equal offsets without scanning
    // every existing child (especially costly for large symbol/archive trees).
    NSUInteger low = 0, high = children.count;
    while (low < high)
    {
      NSUInteger middle = low + (high - low) / 2;
      if ([children[middle] dataRange].location <= node.dataRange.location) low = middle + 1;
      else high = middle;
    }
    [children insertObject:node atIndex:low];
  }

  [nc postNotificationName:MVDataTreeDidChangeNotification 
                    object:layout.dataController];

  [layout.dataController updateTreeView:self];
  
  [layout.dataController.treeLock unlock];
}

//----------------------------------------------------------------------------
- (MVNode *)insertChild:(NSString *)_caption
            location:(uint64_t)location
              length:(uint64_t)length
{
  MVNode * node = [[MVNode alloc] init];
  node.caption = _caption;
  node.dataRange = NSMakeRange(location,length);
  node.parent = self;
  [node.userInfo addEntriesFromDictionary:userInfo];
  [self insertNode:node]; 
  return node;
}

//----------------------------------------------------------------------------
- (MVNode *)insertChildWithDetails:(NSString *)_caption 
                       location:(uint64_t)location
                         length:(uint64_t)length
                          saver:(MVNodeSaver &)saver
{
  MVNode * node = [[MVNode alloc] init];
  node.caption = _caption;
  node.dataRange = NSMakeRange(location, length);
  node.parent = self;
  [node.userInfo addEntriesFromDictionary:userInfo];
  MVLayout * layout = userInfo[MVLayoutUserInfoKey];
  node.details = [MVTable tableWithArchiver:layout.archiver];
  saver.setNode(node);
  [self insertNode:node];
  return node;
}

//----------------------------------------------------------------------------
- (MVNode *)findNodeByUserInfo:(NSDictionary *)uinfo
{
  // act node
  if ([userInfo isEqualToDictionary:uinfo] == YES)
  {
    return self;
  }

  // Traverse a snapshot; parser threads may insert children concurrently.
  NSArray * snapshot;
  @synchronized(children) { snapshot = [children copy]; }
  for (MVNode * node in snapshot)
  {
    MVNode * found = [node findNodeByUserInfo:uinfo];
    if (found != nil)
    {
      return found;
    }
  }
  
  // give up
  return nil;
}

//-----------------------------------------------------------------------------
- (void)openDetails
{
  MVLayout * layout = userInfo[MVLayoutUserInfoKey];
  MVArchiveGuard guard(layout.archiver);
  if (self.details == nil && self.detailsOffset != 0)
  {
    FILE * reader = fopen(layout.archiver.swapPath.fileSystemRepresentation, "rb");
    if (reader == NULL)
      [NSException raise:@"MVSwapFileError" format:@"Cannot open saved details"];
    @try { [self loadFromFile:reader]; }
    @finally { fclose(reader); }
  }
}

//-----------------------------------------------------------------------------
- (void)closeDetails
{
  MVLayout * layout = userInfo[MVLayoutUserInfoKey];
  MVArchiveGuard guard(layout.archiver);
  MVTable * table = self.details;
  if (table.swapFile != NULL)
  {
    fclose(table.swapFile);
    table.swapFile = NULL;
  }
  if (self.detailsOffset != 0 && [layout.archiver canArchive]) self.details = nil;
}

//-----------------------------------------------------------------------------
- (void)sortDetails
{
  MVLayout * layout = userInfo[MVLayoutUserInfoKey];
  MVArchiveGuard guard(layout.archiver);
  [self.details sortByOffset];
}

//----------------------------------------------------------------------------
- (void)filterDetails: (NSString *)filter
{
  MVLayout * layout = userInfo[MVLayoutUserInfoKey];
  MVArchiveGuard guard(layout.archiver);
  [self.details applyFilter:filter];
}

//-----------------------------------------------------------------------------
- (void)saveToFile:(FILE *)pFile
{
  MVLayout * layout = userInfo[MVLayoutUserInfoKey];
  MVArchiveGuard guard(layout.archiver);
  if (self.details == nil) return;
  // Never loan the writer FILE to a table: UI closing/seeking that same stream
  // used to corrupt indexes, and a+ can initially report position zero.
  uint64_t position = [self.details saveIndexesToFile:pFile];
  if (fflush(pFile) != 0)
    [NSException raise:@"MVSwapFileError" format:@"Cannot flush saved details"];
  self.detailsOffset = position;
  [layout.dataController updateTreeView:self];
  if (self == layout.dataController.selectedNode)
    [layout.dataController updateTableView];
}

//-----------------------------------------------------------------------------
- (void)loadFromFile:(FILE *)pFile
{
  MVLayout * layout = userInfo[MVLayoutUserInfoKey];
  MVArchiveGuard guard(layout.archiver);
  NSParameterAssert(self.detailsOffset != 0);
  MVSeek(pFile, self.detailsOffset);
  MVTable * loaded = [MVTable tableWithArchiver:layout.archiver];
  [loaded loadIndexesFromFile:pFile];
  self.details = loaded;
}

//-----------------------------------------------------------------------------
-(void)clear
{
  MVLayout * layout = userInfo[MVLayoutUserInfoKey];
  MVArchiveGuard guard(layout.archiver);
  if (layout.dataController.selectedNode != self && self.detailsOffset != 0 &&
      [layout.archiver canArchive])
    self.details = nil;
}

@end


//============================================================================
@implementation MVDataController

@synthesize fileName, fileData, realData, layouts, rootNode, selectedNode, treeLock;

//-----------------------------------------------------------------------------
/*
- (void)dealloc
{
  NSLog(@"********MVDataController deallocated: %@", self);
  for (MVLayout * layout in layouts)
  {
    NSLog(@"%@ Retain count is %ld", layout, CFGetRetainCount((__bridge CFTypeRef)layout));
  }
}
*/

//-----------------------------------------------------------------------------
-(instancetype)init
{
  if (self = [super init]) 
  {
    layouts = [[NSMutableArray alloc] init];
    rootNode = [[MVNode alloc] init];
    treeLock = [[NSLock alloc] init];
  }
  return self;
}

//----------------------------------------------------------------------------
-(NSString *)getMachine:(cpu_type_t)cputype
{
  switch (cputype)
  {
    default:                  return @"???"; 
    case CPU_TYPE_I386:       return @"X86";
    case CPU_TYPE_POWERPC:    return @"PPC";
    case CPU_TYPE_X86_64:     return @"X86_64";
    case CPU_TYPE_POWERPC64:  return @"PPC64";
    case CPU_TYPE_ARM:        return @"ARM";
    case CPU_TYPE_ARM64:      return @"ARM64";
  }
}

//----------------------------------------------------------------------------
-(NSString *)getARMCpu:(cpu_subtype_t)cpusubtype
{
  switch (cpusubtype)
  {
    default:                      return @"???"; 
    case CPU_SUBTYPE_ARM_ALL:     return @"ARM_ALL";
    case CPU_SUBTYPE_ARM_V4T:     return @"ARM_V4T";
    case CPU_SUBTYPE_ARM_V6:      return @"ARM_V6";
    case CPU_SUBTYPE_ARM_V5TEJ:   return @"ARM_V5TEJ";
    case CPU_SUBTYPE_ARM_XSCALE:  return @"ARM_XSCALE";
    case CPU_SUBTYPE_ARM_V7:      return @"ARM_V7";
    case CPU_SUBTYPE_ARM_V7F:     return @"ARM_V7F";
    case CPU_SUBTYPE_ARM_V7K:     return @"ARM_V7K";
    case CPU_SUBTYPE_ARM_V7S:     return @"ARM_V7S";
    case CPU_SUBTYPE_ARM_V8:      return @"ARM_V8";
  }
}

//----------------------------------------------------------------------------
-(NSString *)getARM64Cpu:(cpu_subtype_t)cpusubtype
{
  switch (cpusubtype & ~CPU_SUBTYPE_MASK)
  {
    default:                      return @"???";
    case CPU_SUBTYPE_ARM64_ALL:   return @"ARM64_ALL";
    case CPU_SUBTYPE_ARM64_V8:    return @"ARM64_V8";
    case CPU_SUBTYPE_ARM64E:      return @"ARM64E";
  }
}

//----------------------------------------------------------------------------
-(BOOL)isSupportedMachine:(NSString *)machine
{
  return ([machine isEqualToString:@"X86"] == YES ||
          [machine isEqualToString:@"X86_64"] == YES ||
          [machine isEqualToString:@"ARM"] == YES ||
          [machine isEqualToString:@"ARM64"] == YES);
}

//----------------------------------------------------------------------------
-(void)createMachOLayout:(MVNode *)node
             mach_header:(struct mach_header const *)mach_header
{
  NSString * machine = [self getMachine:mach_header->cputype];
  
  node.caption = [NSString stringWithFormat:@"%@ (%@)",
                  mach_header->filetype == MH_OBJECT      ? @"Object " :
                  mach_header->filetype == MH_EXECUTE     ? @"Executable " :
                  mach_header->filetype == MH_FVMLIB      ? @"Fixed VM Shared Library" :
                  mach_header->filetype == MH_CORE        ? @"Core" :
                  mach_header->filetype == MH_PRELOAD     ? @"Preloaded Executable" :
                  mach_header->filetype == MH_DYLIB       ? @"Shared Library " : 
                  mach_header->filetype == MH_DYLINKER    ? @"Dynamic Link Editor" :
                  mach_header->filetype == MH_BUNDLE      ? @"Bundle" : 
                  mach_header->filetype == MH_DYLIB_STUB  ? @"Shared Library Stub" : 
                  mach_header->filetype == MH_DSYM        ? @"Debug Symbols" : 
                  mach_header->filetype == MH_KEXT_BUNDLE ? @"Kernel Extension" : @"?????",
                  [machine isEqualToString:@"ARM"] == YES ? [self getARMCpu:mach_header->cpusubtype] : machine];
  
  MachOLayout * layout = [MachOLayout layoutWithDataController:self rootNode:node];
                          
  (node.userInfo)[MVLayoutUserInfoKey] = layout;
  
  if ([self isSupportedMachine:machine])
  {
    [layouts addObject:layout];
  }
  else
  {
    // there is no detail to extract
    [layout.archiver halt];
  }
}

//----------------------------------------------------------------------------
-(void)createMachO64Layout:(MVNode *)node
            mach_header_64:(struct mach_header_64 const *)mach_header_64
{
  NSString * machine = [self getMachine:mach_header_64->cputype];
  
  node.caption = [NSString stringWithFormat:@"%@ (%@)",
                  mach_header_64->filetype == MH_OBJECT      ? @"Object " :
                  mach_header_64->filetype == MH_EXECUTE     ? @"Executable " :
                  mach_header_64->filetype == MH_FVMLIB      ? @"Fixed VM Shared Library" :
                  mach_header_64->filetype == MH_CORE        ? @"Core" :
                  mach_header_64->filetype == MH_PRELOAD     ? @"Preloaded Executable" :
                  mach_header_64->filetype == MH_DYLIB       ? @"Shared Library " :
                  mach_header_64->filetype == MH_DYLINKER    ? @"Dynamic Link Editor" :
                  mach_header_64->filetype == MH_BUNDLE      ? @"Bundle" :
                  mach_header_64->filetype == MH_DYLIB_STUB  ? @"Shared Library Stub" :
                  mach_header_64->filetype == MH_DSYM        ? @"Debug Symbols" :
                  mach_header_64->filetype == MH_KEXT_BUNDLE ? @"Kernel Extension" : @"?????",
                  [machine isEqualToString:@"ARM64"] == YES ? [self getARM64Cpu:mach_header_64->cpusubtype] : machine];
  
  MachOLayout * layout = [MachOLayout layoutWithDataController:self rootNode:node];
  
  (node.userInfo)[MVLayoutUserInfoKey] = layout;
  
  if ([self isSupportedMachine:machine])
  {
    [layouts addObject:layout];
  }
  else
  {
    // there is no detail to extract
    [layout.archiver halt];
  }
}

//----------------------------------------------------------------------------
-(void)createArchiveLayout:(MVNode *)node machine:(NSString *)machine
{
  node.caption = machine ? [NSString stringWithFormat:@"Static Library (%@)", machine] : @"Static Library";

  ArchiveLayout * layout = [ArchiveLayout layoutWithDataController:self rootNode:node];

  (node.userInfo)[MVLayoutUserInfoKey] = layout;

  if (machine == nil || [self isSupportedMachine:machine])
  {
    [layouts addObject:layout];
  }
  else
  {
    // there is no detail to extract
    [layout.archiver halt];
  }
}

//----------------------------------------------------------------------------
// create Mach-O layouts based on file headers
- (void)createLayouts:(MVNode *)parent
             location:(uint64_t)location
               length:(uint64_t)length
{
  if (location > fileData.length || length > fileData.length - location || length < sizeof(uint32_t))
    [NSException raise:@"MVInvalidBinary" format:@"Truncated binary header"];
  parent.dataRange = NSMakeRange((NSUInteger)location, (NSUInteger)length);
  uint32_t magic;
  memcpy(&magic, (const uint8_t *)fileData.bytes + location, sizeof(magic));

  switch (magic)
  {
    case FAT_MAGIC:
    case FAT_CIGAM:
    {
      if (length < sizeof(struct fat_header))
        [NSException raise:@"MVInvalidBinary" format:@"Truncated universal binary header"];
      struct fat_header fat_header;
      [fileData getBytes:&fat_header range:NSMakeRange(location, sizeof(struct fat_header))];
      if (magic == FAT_CIGAM)
        swap_fat_header(&fat_header, NX_LittleEndian);
      [self createFatLayout:parent fat_header:&fat_header];
    } break;
      
    case MH_MAGIC:
    case MH_CIGAM:
    {
      if (length < sizeof(struct mach_header))
        [NSException raise:@"MVInvalidBinary" format:@"Truncated Mach-O header"];
      struct mach_header mach_header;
      [fileData getBytes:&mach_header range:NSMakeRange(location, sizeof(struct mach_header))];
      if (magic == MH_CIGAM)
        swap_mach_header(&mach_header, NX_LittleEndian);
      [self createMachOLayout:parent mach_header:&mach_header];
    } break;
      
    case MH_MAGIC_64:
    case MH_CIGAM_64:
    {
      if (length < sizeof(struct mach_header_64))
        [NSException raise:@"MVInvalidBinary" format:@"Truncated 64-bit Mach-O header"];
      struct mach_header_64 mach_header_64;
      [fileData getBytes:&mach_header_64 range:NSMakeRange(location, sizeof(struct mach_header_64))];
      if (magic == MH_CIGAM_64)
        swap_mach_header_64(&mach_header_64, NX_LittleEndian);
      [self createMachO64Layout:parent mach_header_64:&mach_header_64];
    } break;
      
    case FAT_MAGIC_64:
    case FAT_CIGAM_64:
      [NSException raise:@"MVUnsupportedBinary" format:@"64-bit universal binary indexes are not supported"];
      break;
    default:
      if (length < 8 || memcmp((const uint8_t *)fileData.bytes + location, "!<arch>\n", 8) != 0)
        [NSException raise:@"MVInvalidBinary" format:@"Unrecognized binary header"];
      [self createArchiveLayout:parent machine:nil];
  }
}

//----------------------------------------------------------------------------
-(void)createFatLayout:(MVNode *)node
            fat_header:(struct fat_header const *)fat_header
{
  node.caption = @"Fat Binary";
  FatLayout * layout = [FatLayout layoutWithDataController:self rootNode:node];
  
  (node.userInfo)[MVLayoutUserInfoKey] = layout;
  
  [layouts addObject:layout];
  NSRange range = node.dataRange;
  if (fat_header->nfat_arch > (range.length - sizeof(struct fat_header)) / sizeof(struct fat_arch))
    [NSException raise:@"MVInvalidBinary" format:@"Truncated universal binary index"];
  uint32_t diskMagic;
  memcpy(&diskMagic, (const uint8_t *)fileData.bytes + range.location, sizeof(diskMagic));
  for (uint32_t nimg = 0; nimg < fat_header->nfat_arch; ++nimg)
  {
    struct fat_arch fat_arch;
    [fileData getBytes:&fat_arch range:NSMakeRange(range.location + sizeof(struct fat_header) +
                                                  (NSUInteger)nimg * sizeof(struct fat_arch), sizeof(struct fat_arch))];
    if (diskMagic == FAT_CIGAM) swap_fat_arch(&fat_arch, 1, NX_LittleEndian);
    NSUInteger indexEnd = sizeof(struct fat_header) + (NSUInteger)fat_header->nfat_arch * sizeof(struct fat_arch);
    if (fat_arch.offset < indexEnd || fat_arch.offset > range.length || fat_arch.size > range.length - fat_arch.offset)
      [NSException raise:@"MVInvalidBinary" format:@"Universal binary slice extends beyond its container"];
    NSUInteger offset = range.location + fat_arch.offset;
    MVNode * archNode = [node insertChild:nil location:offset length:fat_arch.size];
    if (fat_arch.size >= 8 && memcmp((const uint8_t *)fileData.bytes + offset, "!<arch>\n", 8) == 0)
      [self createArchiveLayout:archNode machine:[self getMachine:fat_arch.cputype]];
    else
      [self createLayouts:archNode location:offset length:fat_arch.size];
  }
}

//----------------------------------------------------------------------------
- (void)treeViewWillChange
{
  NSNotificationCenter * nc = [NSNotificationCenter defaultCenter];
  [nc postNotificationName:MVDataTreeWillChangeNotification 
                    object:self];
}

//----------------------------------------------------------------------------
- (void)treeViewDidChange
{
  NSNotificationCenter * nc = [NSNotificationCenter defaultCenter];
  [nc postNotificationName:MVDataTreeDidChangeNotification 
                    object:self];
}

//----------------------------------------------------------------------------
- (void)updateTreeView: (MVNode *)node
{
  NSNotificationCenter * nc = [NSNotificationCenter defaultCenter];
  [nc postNotificationName:MVDataTreeChangedNotification 
                    object:self
                  userInfo:node ? @{MVNodeUserInfoKey: node} : nil];
}

//-----------------------------------------------------------------------------
- (void)updateTableView
{
  NSNotificationCenter * nc = [NSNotificationCenter defaultCenter];
  [nc postNotificationName:MVDataTableChangedNotification 
                    object:self];
}

//-----------------------------------------------------------------------------
- (void)updateStatus: (NSString *)status
{
  NSNotificationCenter * nc = [NSNotificationCenter defaultCenter];
  [nc postNotificationName:MVThreadStateChangedNotification 
                    object:self
                  userInfo:@{MVStatusUserInfoKey: status}];
}

@end

#pragma mark -

//============================================================================
@implementation MVArchiver

@synthesize swapPath;

+ (NSOperationQueue *)writerQueue
{
  static NSOperationQueue * queue;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    queue = [[NSOperationQueue alloc] init];
    queue.name = @"MachOView swap writer";
    queue.maxConcurrentOperationCount = 1;
    queue.qualityOfService = NSQualityOfServiceUtility;
  });
  return queue;
}

- (instancetype)init
{
  NSAssert(NO, @"plain init is not allowed");
  return nil;
}

- (instancetype)initWithPath:(NSString *)path
{
  if (self = [super init])
  {
    objectsToSave = [[NSMutableOrderedSet alloc] init];
    saverLock = [[NSRecursiveLock alloc] init];
    // Never truncate an existing file or follow a temporary-file symlink.
    int descriptor = open(path.fileSystemRepresentation, O_CREAT | O_EXCL | O_RDWR, 0600);
    if (descriptor < 0) return nil;
    FILE * file = fdopen(descriptor, "w+b");
    if (file == NULL)
    {
      close(descriptor);
      unlink(path.fileSystemRepresentation);
      return nil;
    }
    BOOL wroteHeader = fputs("!<MachoViewSwapFile 2.0>\n", file) != EOF;
    BOOL closed = fclose(file) == 0;
    if (!wroteHeader || !closed)
    {
      unlink(path.fileSystemRepresentation);
      return nil;
    }
    swapPath = [path copy];
  }
  return self;
}

- (void)dealloc
{
  if (swapPath != nil) unlink(swapPath.fileSystemRepresentation);
}

+ (MVArchiver *)archiverWithPath:(NSString *)path
{
  return [[MVArchiver alloc] initWithPath:path];
}

- (void)suspend { [saverLock lock]; }
- (void)resume { [saverLock unlock]; }

- (BOOL)canArchive
{
  MVArchiveGuard guard(self);
#ifdef MV_NO_ARCHIVER
  return NO;
#else
  return !saveFailed;
#endif
}

// Called under saverLock; one queued operation per archiver, not per row.
- (void)scheduleSave
{
  if (saveScheduled || saveFailed || objectsToSave.count == 0) return;
  saveScheduled = YES;
  [[MVArchiver writerQueue] addOperationWithBlock:^{
    @autoreleasepool
    {
      MVArchiveGuard guard(self);
      [self saveBatch];
      self->saveScheduled = NO;
      [self scheduleSave]; // yield to other documents between bounded batches
    }
  }];
}

- (void)addObjectToSave:(id)object
{
  if (object == nil) return;
  NSParameterAssert([object conformsToProtocol:@protocol(MVSerializing)]);
  MVArchiveGuard guard(self);
  if (![self canArchive]) return;
  [objectsToSave addObject:object];
  // Backpressure bounds pending objects even if a parser outruns disk I/O.
  // The same lock serializes this inline drain with the background writer.
  if (objectsToSave.count >= 4096) [self saveBatch];
  [self scheduleSave];
}

- (void)saveBatch
{
  if (saveFailed || objectsToSave.count == 0) return;
  @autoreleasepool
  {
    NSUInteger count = MIN(objectsToSave.count, (NSUInteger)256);
    NSArray * batch = [objectsToSave objectsAtIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, count)]];
    FILE * writer = fopen(swapPath.fileSystemRepresentation, "r+b");
    @try
    {
      // a+ does not guarantee its INITIAL read position is at EOF. r+b plus
      // an explicit seek makes all recorded offsets match actual writes.
      if (writer == NULL || fseeko(writer, 0, SEEK_END) != 0)
        [NSException raise:@"MVSwapFileError" format:@"Cannot open swap writer"];
      for (id<MVSerializing> object in batch) [object saveToFile:writer];
      if (fflush(writer) != 0)
        [NSException raise:@"MVSwapFileError" format:@"Cannot flush swap writer"];
      int result = fclose(writer);
      writer = NULL;
      if (result != 0)
        [NSException raise:@"MVSwapFileError" format:@"Cannot close swap writer"];
      [objectsToSave removeObjectsInRange:NSMakeRange(0, count)];
      // Evict ONLY after the entire batch has been made visible to readers.
      for (id<MVSerializing> object in batch) [object clear];
    }
    @catch (NSException * exception)
    {
      saveFailed = YES;
      // Keep the live model intact, and stop retrying a full/unwritable disk.
      [objectsToSave removeAllObjects];
      NSLog(@"Swap archiving disabled for %@: %@", swapPath, exception.reason);
    }
    @finally
    {
      if (writer != NULL) fclose(writer);
    }
  }
}

- (void)flush
{
  MVArchiveGuard guard(self);
  while (!saveFailed && objectsToSave.count != 0) [self saveBatch];
}

- (void)halt
{
  // No immortal worker to cancel/join. Later UI edits use the same writer path.
  [self flush];
}

@end

//-----------------------------------------------------------------------------
MVNodeSaver::MVNodeSaver() 
  : m_node(nil) 
{
}

//-----------------------------------------------------------------------------
MVNodeSaver::~MVNodeSaver() 
{
  MVLayout * layout = (m_node.userInfo)[MVLayoutUserInfoKey];
  [layout.archiver addObjectToSave:m_node];
}
