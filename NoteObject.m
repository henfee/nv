//
//  NoteObject.m
//  Notation
//
//  Created by Zachary Schneirov on 12/19/05.
//  Copyright 2005 Zachary Schneirov. All rights reserved.
//

#import "NoteObject.h"
#import "GlobalPrefs.h"
#import "LabelObject.h"
#import "WALController.h"
#import "NotationController.h"
#import "NotationPrefs.h"
#import "AttributedPlainText.h"
#import "NSString_NV.h"
#include "BufferUtils.h"
#import "NotationFileManager.h"

#define CURRENT_NOTE_ARCHIVING_VERSION 1

#if __LP64__
// Needed for compatability with data created by 32bit app
typedef struct NSRange32 {
    unsigned int location;
    unsigned int length;
} NSRange32;
#else
typedef NSRange NSRange32;
#endif

@implementation NoteObject

static NSStringEncoding systemStringEncoding;
static BOOL DidCheckNoteVersion = NO;
static FSRef *noteFileRefInit(NoteObject* obj);

+ (void)initialize {
	if (self == [NoteObject class])
		[NoteObject setVersion:CURRENT_NOTE_ARCHIVING_VERSION];
	
	systemStringEncoding = CFStringConvertEncodingToNSStringEncoding(CFStringGetSystemEncoding());
	if (systemStringEncoding == kCFStringEncodingInvalidId) {
		NSLog(@"default string encoding conversion invalid? using macosroman...");
		systemStringEncoding = NSMacOSRomanStringEncoding;
	}
}

- (id)init {
    if ([super init]) {
	
	cTitle = cContents = cLabels = cTitleFoundPtr = cContentsFoundPtr = cLabelsFoundPtr = NULL;
	
	bzero(&fileModifiedDate, sizeof(UTCDateTime));
	modifiedDate = createdDate = 0.0;
	currentFormatID = SingleDatabaseFormat;
	nodeID = 0;
	//TODO: use UTF-8 instead
	fileEncoding = systemStringEncoding;
	contentsWere7Bit = NO;
	
	serverModifiedTime = 0;
	logSequenceNumber = 0;
	selectedRange = NSMakeRange(NSNotFound, 0);
	scrolledProportion = 0.0f;
	
	//these are created either when the object is initialized from disk or when it writes its files to disk
	//bzero(&noteFileRef, sizeof(FSRef));
	
	//labelSet = [[NSMutableSet alloc] init];
	
    }
	
    return self;
}

- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	
	[self invalidateFSRef];
	
	[tableTitleString release];
	[titleString release];
	[labelString release];
	[labelSet release];
	[undoManager release];
	[filename release];
	[dateModifiedString release];
	[dateCreatedString release];
		
	if (cTitle)
		free(cTitle);
	if (cContents)
		free(cContents);
	if (cLabels)
	    free(cLabels);
	
	[super dealloc];
}

- (id)delegate {
	return delegate;
}

- (void)setDelegate:(id)theDelegate {
	delegate = theDelegate;
	
	//clean up anything else that couldn't be set due to the note being created without knowledge of its delegate
	if (!filename) {
		filename = [[delegate uniqueFilenameForTitle:titleString fromNote:self] retain];
	}
}

static FSRef *noteFileRefInit(NoteObject* obj) {
	if (!(obj->noteFileRef)) {
		obj->noteFileRef = (FSRef*)calloc(1, sizeof(FSRef));
	}
	return obj->noteFileRef;
}

NSInteger compareFilename(id *one, id *two) {
    
    return (int)CFStringCompare((CFStringRef)((*(NoteObject**)one)->filename), 
				(CFStringRef)((*(NoteObject**)two)->filename), kCFCompareCaseInsensitive);
}

NSInteger compareDateModified(id *a, id *b) {
    return (*(NoteObject**)a)->modifiedDate - (*(NoteObject**)b)->modifiedDate;
}
NSInteger compareDateCreated(id *a, id *b) {
    return (*(NoteObject**)a)->createdDate - (*(NoteObject**)b)->createdDate;
}
NSInteger compareLabelString(id *a, id *b) {    
    return (int)CFStringCompare((CFStringRef)(labelsOfNote(*(NoteObject **)a)), 
								(CFStringRef)(labelsOfNote(*(NoteObject **)b)), kCFCompareCaseInsensitive);
}
NSInteger compareTitleString(id *a, id *b) {
    CFComparisonResult stringResult = CFStringCompare((CFStringRef)(titleOfNote(*(NoteObject**)a)), 
													  (CFStringRef)(titleOfNote(*(NoteObject**)b)), 
													  kCFCompareCaseInsensitive);
	if (stringResult == kCFCompareEqualTo) {
		
		int dateResult = compareDateCreated(a, b);
		if (!dateResult)
			return compareUniqueNoteIDBytes(a, b);
		
		return dateResult;
	}
	
	return (int)stringResult;
}
NSInteger compareUniqueNoteIDBytes(id *a, id *b) {
	return memcmp((&(*(NoteObject**)a)->uniqueNoteIDBytes), (&(*(NoteObject**)b)->uniqueNoteIDBytes), sizeof(CFUUIDBytes));
}


NSInteger compareDateModifiedReverse(id *a, id *b) {
    return (*(NoteObject**)b)->modifiedDate - (*(NoteObject**)a)->modifiedDate;
}
NSInteger compareDateCreatedReverse(id *a, id *b) {
    return (*(NoteObject**)b)->createdDate - (*(NoteObject**)a)->createdDate;
}
NSInteger compareLabelStringReverse(id *a, id *b) {    
    return (int)CFStringCompare((CFStringRef)(labelsOfNote(*(NoteObject **)b)), 
								(CFStringRef)(labelsOfNote(*(NoteObject **)a)), kCFCompareCaseInsensitive);
}
NSInteger compareTitleStringReverse(id *a, id *b) {
    CFComparisonResult stringResult = CFStringCompare((CFStringRef)(titleOfNote(*(NoteObject **)b)), 
													  (CFStringRef)(titleOfNote(*(NoteObject **)a)), 
													  kCFCompareCaseInsensitive);
	
	if (stringResult == kCFCompareEqualTo) {
		int dateResult = compareDateCreatedReverse(a, b);
		if (!dateResult)
			return compareUniqueNoteIDBytes(b, a);
		
		return dateResult;
	}
	return (int)stringResult;	
}

NSInteger compareNodeID(id *a, id *b) {
    return (*(NoteObject**)a)->nodeID - (*(NoteObject**)b)->nodeID;
}


//syncing w/ server and from journal; these should be objc methods so we can use polymorphism
- (CFUUIDBytes *)uniqueNoteIDBytes {
    return &uniqueNoteIDBytes;
}
- (unsigned int)serverModifiedDate {
    return serverModifiedTime;
}
- (unsigned int)logSequenceNumber {
    return logSequenceNumber;
}
- (void)incrementLSN {
    logSequenceNumber++;
}
- (BOOL)youngerThanLogObject:(id<SynchronizedNote>)obj {
	return [self logSequenceNumber] < [obj logSequenceNumber];
}

//inlines won't make a difference in GCC, as these functions are called almost exclusively from other files

force_inline NSString* wordCountOfNote(NoteObject *note) {
	return note->wordCountString;
}

force_inline NSString* filenameOfNote(NoteObject *note) {
    return note->filename;
}

force_inline UInt32 fileNodeIDOfNote(NoteObject *note) {
    return note->nodeID;
}

force_inline NSString* titleOfNote(NoteObject *note) {
    return note->titleString;
}

force_inline NSString* labelsOfNote(NoteObject *note) {
	return note->labelString;
}

force_inline NSAttributedString* tableTitleOfNote(NoteObject *note) {
	return note->tableTitleString;
}

force_inline UTCDateTime fileModifiedDateOfNote(NoteObject *note) {
    return note->fileModifiedDate;
}

force_inline int storageFormatOfNote(NoteObject *note) {
    return note->currentFormatID;
}

force_inline NSStringEncoding fileEncodingOfNote(NoteObject *note) {
	return note->fileEncoding;
}

force_inline NSString *dateCreatedStringOfNote(NoteObject *note) {
	return note->dateCreatedString;
}

force_inline NSString *dateModifiedStringOfNote(NoteObject *note) {
	return note->dateModifiedString;
}

//make notationcontroller should send setDelegate: and setLabelString: (if necessary) to each note when unarchiving this way

//there is no measurable difference in speed when using decodeValuesOfObjCTypes, oddly enough
//the overhead of the _decodeObject* C functions must be significantly greater than the objc_msgSend and argument passing overhead
#define DECODE_INDIVIDUALLY 1

- (id)initWithCoder:(NSCoder*)decoder {
	if ([self init]) {
		
		if ([decoder allowsKeyedCoding]) {
			//(hopefully?) no versioning necessary here
			
			modifiedDate = [decoder decodeDoubleForKey:VAR_STR(modifiedDate)];
			createdDate = [decoder decodeDoubleForKey:VAR_STR(createdDate)];
			selectedRange.location = [decoder decodeInt32ForKey:@"selectionRangeLocation"];
			selectedRange.length = [decoder decodeInt32ForKey:@"selectionRangeLength"];
			scrolledProportion = [decoder decodeFloatForKey:VAR_STR(scrolledProportion)];
			
			logSequenceNumber = [decoder decodeInt32ForKey:VAR_STR(logSequenceNumber)];

			currentFormatID = [decoder decodeInt32ForKey:VAR_STR(currentFormatID)];
			nodeID = [decoder decodeInt32ForKey:VAR_STR(nodeID)];
			fileModifiedDate.highSeconds = [decoder decodeInt32ForKey:@"fileModDateHigh"];
			fileModifiedDate.lowSeconds = [decoder decodeInt32ForKey:@"fileModDateLow"];
			fileModifiedDate.fraction = [decoder decodeInt32ForKey:@"fileModDateFrac"];
			fileEncoding = [decoder decodeInt32ForKey:VAR_STR(fileEncoding)];

			NSUInteger decodedByteCount;
			const uint8_t *decodedBytes = [decoder decodeBytesForKey:VAR_STR(uniqueNoteIDBytes) returnedLength:&decodedByteCount];
			memcpy(&uniqueNoteIDBytes, decodedBytes, MIN(decodedByteCount, sizeof(CFUUIDBytes)));
			serverModifiedTime = [decoder decodeInt32ForKey:VAR_STR(serverModifiedTime)];
			
			titleString = [[decoder decodeObjectForKey:VAR_STR(titleString)] retain];
			labelString = [[decoder decodeObjectForKey:VAR_STR(labelString)] retain];
			contentString = [[decoder decodeObjectForKey:VAR_STR(contentString)] retain];
			filename = [[decoder decodeObjectForKey:VAR_STR(filename)] retain];
			
		} else {
			if (!DidCheckNoteVersion) {
				int version = [decoder versionForClassName:NSStringFromClass([NoteObject class])];
				
				if (version > CURRENT_NOTE_ARCHIVING_VERSION) {
					//need to warn user here, too, but this is not the right place
					NSLog(@"Note version %d is newer than current (%d)", version, CURRENT_NOTE_ARCHIVING_VERSION);
					return nil;
				}
				DidCheckNoteVersion = YES;
			}
            NSRange32 range32;
            #if __LP64__
            unsigned long longTemp;
            #endif
#if DECODE_INDIVIDUALLY
			[decoder decodeValueOfObjCType:@encode(CFAbsoluteTime) at:&modifiedDate];
			[decoder decodeValueOfObjCType:@encode(CFAbsoluteTime) at:&createdDate];
            #if __LP64__
			[decoder decodeValueOfObjCType:"{_NSRange=II}" at:&range32];
            #else
            [decoder decodeValueOfObjCType:@encode(NSRange) at:&range32];
            #endif
			[decoder decodeValueOfObjCType:@encode(float) at:&scrolledProportion];
			
			[decoder decodeValueOfObjCType:@encode(unsigned int) at:&logSequenceNumber];
			
			[decoder decodeValueOfObjCType:@encode(int) at:&currentFormatID];
            #if __LP64__
            [decoder decodeValueOfObjCType:"L" at:&longTemp];
            nodeID = (UInt32)longTemp;
            #else
			[decoder decodeValueOfObjCType:@encode(UInt32) at:&nodeID];
            #endif
			[decoder decodeValueOfObjCType:@encode(UInt16) at:&fileModifiedDate.highSeconds];
            #if __LP64__
			[decoder decodeValueOfObjCType:"L" at:&longTemp];
            fileModifiedDate.lowSeconds = (UInt32)longTemp;
            #else
            [decoder decodeValueOfObjCType:@encode(UInt32) at:&fileModifiedDate.lowSeconds];
            #endif
			[decoder decodeValueOfObjCType:@encode(UInt16) at:&fileModifiedDate.fraction];	
            
            #if __LP64__
            [decoder decodeValueOfObjCType:"I" at:&fileEncoding];
            #else
            [decoder decodeValueOfObjCType:@encode(NSStringEncoding) at:&fileEncoding];
            #endif
			
			[decoder decodeValueOfObjCType:@encode(CFUUIDBytes) at:&uniqueNoteIDBytes];
			[decoder decodeValueOfObjCType:@encode(unsigned int) at:&serverModifiedTime];
			
			titleString = [[decoder decodeObject] retain];
			labelString = [[decoder decodeObject] retain];
			contentString = [[decoder decodeObject] retain];
			filename = [[decoder decodeObject] retain];
#else 
			[decoder decodeValuesOfObjCTypes: "dd{NSRange=ii}fIiI{UTCDateTime=SIS}I[16C]I@@@@", &modifiedDate, &createdDate, &range32, 
				&scrolledProportion, &logSequenceNumber, &currentFormatID, &nodeID, &fileModifiedDate, &fileEncoding, &uniqueNoteIDBytes, 
				&serverModifiedTime, &titleString, &labelString, &contentString, &filename];
#endif
            selectedRange.location = range32.location;
            selectedRange.length = range32.length;
		}
		
		contentsWere7Bit = (*(unsigned int*)&scrolledProportion) != 0; //hacko wacko
	
		//re-created at runtime to save space
		[self initContentCacheCString];
		cTitleFoundPtr = cTitle = strdup([titleString lowercaseUTF8String]);
		cLabelsFoundPtr = cLabels = strdup([labelString lowercaseUTF8String]);
		
		dateCreatedString = [[NSString relativeDateStringWithAbsoluteTime:createdDate] retain];
		dateModifiedString = [[NSString relativeDateStringWithAbsoluteTime:modifiedDate] retain];
		
		//[self updateTablePreviewString];
	}
	return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
	
	*(unsigned int*)&scrolledProportion = (unsigned int)contentsWere7Bit;
	
	if ([coder allowsKeyedCoding]) {
		
		[coder encodeDouble:modifiedDate forKey:VAR_STR(modifiedDate)];
		[coder encodeDouble:createdDate forKey:VAR_STR(createdDate)];
		[coder encodeInt32:(unsigned int)selectedRange.location forKey:@"selectionRangeLocation"];
		[coder encodeInt32:(unsigned int)selectedRange.length forKey:@"selectionRangeLength"];
		[coder encodeFloat:scrolledProportion forKey:VAR_STR(scrolledProportion)];
		
		[coder encodeInt32:logSequenceNumber forKey:VAR_STR(logSequenceNumber)];
		
		[coder encodeInt32:currentFormatID forKey:VAR_STR(currentFormatID)];
		[coder encodeInt32:nodeID forKey:VAR_STR(nodeID)];

		[coder encodeInt32:fileModifiedDate.highSeconds forKey:@"fileModDateHigh"];
		[coder encodeInt32:fileModifiedDate.lowSeconds forKey:@"fileModDateLow"];
		[coder encodeInt32:fileModifiedDate.fraction forKey:@"fileModDateFrac"];
		[coder encodeInt32:fileEncoding forKey:VAR_STR(fileEncoding)];
		
		[coder encodeBytes:(const uint8_t *)&uniqueNoteIDBytes length:sizeof(CFUUIDBytes) forKey:VAR_STR(uniqueNoteIDBytes)];
		[coder encodeInt32:serverModifiedTime forKey:VAR_STR(serverModifiedTime)];
		
		[coder encodeObject:titleString forKey:VAR_STR(titleString)];
		[coder encodeObject:labelString forKey:VAR_STR(labelString)];
		[coder encodeObject:contentString forKey:VAR_STR(contentString)];
		[coder encodeObject:filename forKey:VAR_STR(filename)];
		
	} else {
// 64bit encoding would break 32bit reading - keyed archives should be used
#if !__LP64__
#if DECODE_INDIVIDUALLY
		[coder encodeValueOfObjCType:@encode(CFAbsoluteTime) at:&modifiedDate];
		[coder encodeValueOfObjCType:@encode(CFAbsoluteTime) at:&createdDate];
        [coder encodeValueOfObjCType:@encode(NSRange) at:&selectedRange];
		[coder encodeValueOfObjCType:@encode(float) at:&scrolledProportion];
		
		[coder encodeValueOfObjCType:@encode(unsigned int) at:&logSequenceNumber];
		
		[coder encodeValueOfObjCType:@encode(int) at:&currentFormatID];
		[coder encodeValueOfObjCType:@encode(UInt32) at:&nodeID];	
		[coder encodeValueOfObjCType:@encode(UInt16) at:&fileModifiedDate.highSeconds];
		[coder encodeValueOfObjCType:@encode(UInt32) at:&fileModifiedDate.lowSeconds];
		[coder encodeValueOfObjCType:@encode(UInt16) at:&fileModifiedDate.fraction];
		[coder encodeValueOfObjCType:@encode(NSStringEncoding) at:&fileEncoding];
		
		[coder encodeValueOfObjCType:@encode(CFUUIDBytes) at:&uniqueNoteIDBytes];
		[coder encodeValueOfObjCType:@encode(unsigned int) at:&serverModifiedTime];
		
		[coder encodeObject:titleString];
		[coder encodeObject:labelString];
		[coder encodeObject:contentString];
		[coder encodeObject:filename];
		
#else
		[coder encodeValuesOfObjCTypes: "dd{NSRange=ii}fIiI{UTCDateTime=SIS}I[16C]I@@@@", &modifiedDate, &createdDate, &range32, 
			&scrolledProportion, &logSequenceNumber, &currentFormatID, &nodeID, &fileModifiedDate, &fileEncoding, &uniqueNoteIDBytes, 
			&serverModifiedTime, &titleString, &labelString, &contentString, &filename];
#endif
#endif // !__LP64__
	}
}

- (id)initWithNoteBody:(NSAttributedString*)bodyText title:(NSString*)aNoteTitle uniqueFilename:(NSString*)aFilename format:(int)formatID {
    if ([self init]) {
		
		if (!bodyText || !aNoteTitle) {
			return nil;
		}

		contentString = [[NSMutableAttributedString alloc] initWithAttributedString:bodyText];
		[self initContentCacheCString];
		if (!cContents) {
			NSLog(@"couldn't get UTF8 string from contents?!?");
			return nil;
		}

		if (![self _setTitleString:aNoteTitle])
		    titleString = NSLocalizedString(@"Untitled Note", @"Title of a nameless note");
		
		//[self updateTablePreviewString];
		
		labelString = @"";
		cLabelsFoundPtr = cLabels = strdup("");
		
		filename = [aFilename retain];
		currentFormatID = formatID;
		
		CFUUIDRef uuidRef = CFUUIDCreate(kCFAllocatorDefault);
		uniqueNoteIDBytes = CFUUIDGetUUIDBytes(uuidRef);
		CFRelease(uuidRef);
		
		createdDate = modifiedDate = CFAbsoluteTimeGetCurrent();
		dateCreatedString = [dateModifiedString = [[NSString relativeDateStringWithAbsoluteTime:modifiedDate] retain] retain];
		if (UCConvertCFAbsoluteTimeToUTCDateTime(modifiedDate, &fileModifiedDate) != noErr)
		    NSLog(@"Error initializing file modification date");
		
		//delegate is not set yet, so we cannot dirty ourselves here
		//[self makeNoteDirty];
    }
    
    return self;
}

//only get the fsrefs until we absolutely need them

- (id)initWithCatalogEntry:(NoteCatalogEntry*)entry delegate:(id)aDelegate {
    if ([self init]) {
		delegate = aDelegate;
		filename = [(NSString*)entry->filename copy];
		currentFormatID = [delegate currentNoteStorageFormat];
		fileModifiedDate = entry->lastModified;
		nodeID = entry->nodeID;
		
		CFUUIDRef uuidRef = CFUUIDCreate(kCFAllocatorDefault);
		uniqueNoteIDBytes = CFUUIDGetUUIDBytes(uuidRef);
		CFRelease(uuidRef);
		
		if (![self _setTitleString:[filename stringByDeletingPathExtension]])
			titleString = NSLocalizedString(@"Untitled Note", @"Title of a nameless note");
		
		labelString = @""; //I'd like to get labels from getxattr
		cLabelsFoundPtr = cLabels = strdup("");	
		
		createdDate = modifiedDate = CFAbsoluteTimeGetCurrent(); //TODO: use the file's mod/create dates instead
		dateCreatedString = [dateModifiedString = [[NSString relativeDateStringWithAbsoluteTime:modifiedDate] retain] retain];
		
		contentString = [[NSMutableAttributedString alloc] initWithString:@""];
		[self initContentCacheCString];
		
		if (![self updateFromCatalogEntry:entry]) {
			//just initialize a blank note for now; if the file becomes readable again we'll be updated
			//but if we make modifications, well, the original is toast
			//so warn the user here and offer to trash it?
			//perhaps also offer to re-interpret using another text encoding?
			
			//additionally, it is possible that the file was deleted before we could read it
		}
    }
	
	//[self updateTablePreviewString];
    
    return self;
}

//assume any changes have been synchronized with undomanager
- (void)setContentString:(NSAttributedString*)attributedString {
	if (attributedString) {
		[contentString setAttributedString:attributedString];
		
		//[self updateTablePreviewString];
		contentCacheNeedsUpdate = YES;
		//[self updateContentCacheCStringIfNecessary];
	
		[self makeNoteDirtyUpdateTime:YES updateFile:YES];
	}
}
- (NSAttributedString*)contentString {
	return contentString;
}

- (void)updateContentCacheCStringIfNecessary {
	if (contentCacheNeedsUpdate) {
		//NSLog(@"updating ccache strs");
		cContentsFoundPtr = cContents = replaceString(cContents, [[contentString string] lowercaseUTF8String]);
		contentCacheNeedsUpdate = NO;
		
		int len = strlen(cContents);
		contentsWere7Bit = !(ContainsHighAscii(cContents, len));
		
		//could cache dumbwordcount here for faster launch, but string creation takes more time, anyway
		//if (wordCountString) CFRelease((CFStringRef*)wordCountString); //this is CFString, so bridge will just call back to CFRelease, anyway
		//wordCountString = (NSString*)CFStringFromBase10Integer(DumbWordCount(cContents, len));
	}
}

static int decoded7Bit = 0;
- (void)initContentCacheCString {

	if (contentsWere7Bit) {
	//	NSLog(@"decoding %X as 7-bit", self);
		decoded7Bit++;
		if (!(cContentsFoundPtr = cContents = [[contentString string] copyLowercaseASCIIString]))
			contentsWere7Bit = NO;
	}
	
	int len = -1;
	
	if (!contentsWere7Bit) {
		const char *cStringData = [[contentString string] lowercaseUTF8String];
		cContentsFoundPtr = cContents = cStringData ? strdup(cStringData) : NULL;
		
		contentsWere7Bit = !(ContainsHighAscii(cContents, (len = strlen(cContents))));
	}
	
	//if (len < 0) len = strlen(cContents);
	//wordCountString = (NSString*)CFStringFromBase10Integer(DumbWordCount(cContents, len));
	
	contentCacheNeedsUpdate = NO;
}
int decodedCount() {
	return decoded7Bit;
}

- (NSAttributedString*)printableStringRelativeToBodyFont:(NSFont*)bodyFont {
	NSFont *titleFont = [NSFont fontWithName:[bodyFont fontName] size:[bodyFont pointSize] + 6.0f];
	
	NSDictionary *dict = [NSDictionary dictionaryWithObjectsAndKeys:titleFont, NSFontAttributeName, nil];
	
	NSMutableAttributedString *largeAttributedTitleString = [[[NSMutableAttributedString alloc] initWithString:titleString attributes:dict] autorelease];
	
	NSAttributedString *noAttrBreak = [[NSAttributedString alloc] initWithString:@"\n\n\n" attributes:nil];
	[largeAttributedTitleString appendAttributedString:noAttrBreak];
	[noAttrBreak release];

	//other header things here, too? like date created/mod/printed? tags?
	[largeAttributedTitleString appendAttributedString:[self contentString]];
	
	return largeAttributedTitleString;
}

- (void)updateTablePreviewString {
	return;
	[tableTitleString release];
	tableTitleString = [[titleString attributedPreviewFromBodyText:contentString] retain];
}

- (void)setTitleString:(NSString*)aNewTitle {
	
	NSString *oldTitle = [titleString retain];
	
    if ([self _setTitleString:aNewTitle]) {
		//do you really want to do this when the format is a single DB and the file on disk hasn't been removed?
		//the filename could get out of sync if we lose the fsref and we could end up with a second file after note is rewritten
		
		//solution: don't change the name in that case and allow its new name to be generated
		//when the format is changed and the file rewritten?
		
		
		
		//however, the filename is used for exporting and potentially other purposes, so we should also update
		//it if we know that is has no currently existing (older) counterpart in the notes directory
		
		//woe to the exporter who also left the note files in the notes directory after switching to a singledb format
		//his note names might not be up-to-date
		if ([delegate currentNoteStorageFormat] != SingleDatabaseFormat || 
			![delegate notesDirectoryContainsFile:filename returningFSRef:noteFileRefInit(self)]) {
			
			[self setFilenameFromTitle];
		}
		
		//yes, the given extension could be different from what we had before
		//but makeNoteDirty will eventually cause it to be re-written in the current format
		//and thus the format ID will be changed if that was the case
		[self makeNoteDirtyUpdateTime:YES updateFile:YES];
		
		//[self updateTablePreviewString];
		
		/*NSUndoManager *undoMan = [delegate undoManager];
		[undoMan registerUndoWithTarget:self selector:@selector(setTitleString:) object:oldTitle];
		if (![undoMan isUndoing] && ![undoMan isRedoing])
			[undoMan setActionName:[NSString stringWithFormat:@"Rename Note \"%@\"", titleString]];
		*/
		[oldTitle release];
		
		[delegate note:self attributeChanged:NoteTitleColumnString];
    }
}

- (BOOL)_setTitleString:(NSString*)aNewTitle {
    if (!aNewTitle || ![aNewTitle length] || (titleString && [aNewTitle isEqualToString:titleString]))
	return NO;
    
    [titleString release];
    titleString = [aNewTitle copy];
    
    cTitleFoundPtr = cTitle = replaceString(cTitle, [titleString lowercaseUTF8String]);
    
    return YES;
}

- (void)setFilenameFromTitle {
	[self setFilename:[delegate uniqueFilenameForTitle:titleString fromNote:self] withExternalTrigger:NO];
}

- (void)setFilename:(NSString*)aString withExternalTrigger:(BOOL)externalTrigger {
    
    if (!filename || ![aString isEqualToString:filename]) {
		NSString *oldName = filename;
		filename = [aString copy];
		
		if (!externalTrigger) {
			if ([delegate noteFileRenamed:noteFileRefInit(self) fromName:oldName toName:filename] != noErr) {
				NSLog(@"Couldn't rename note %@", titleString);
				
				//revert name
				[filename release];
				filename = [oldName retain];
				return;
			}
		} else {
			[self _setTitleString:[aString stringByDeletingPathExtension]];	
			
			[delegate note:self attributeChanged:NoteTitleColumnString];
		}
		
		[self makeNoteDirtyUpdateTime:YES updateFile:NO];
		
		[delegate updateLinksToNote:self fromOldName:oldName];
		//update all the notes that link to the old filename as well!!
		
		[oldName release];
    }
}

//how do we write a thousand RTF files at once, repeatedly? 

- (void)updateUnstyledTextWithBaseFont:(NSFont*)baseFont {

	if ([contentString restyleTextToFont:[[GlobalPrefs defaultPrefs] noteBodyFont] usingBaseFont:baseFont] > 0) {
		[undoManager removeAllActions];
		
		if ([delegate currentNoteStorageFormat] == RTFTextFormat)
			[self makeNoteDirtyUpdateTime:NO updateFile:YES];
	}
}

- (void)updateDateStrings {
	[dateModifiedString release];
	[dateCreatedString release];
	
	dateCreatedString = [[NSString relativeDateStringWithAbsoluteTime:createdDate] retain];
	dateModifiedString = [[NSString relativeDateStringWithAbsoluteTime:modifiedDate] retain];
}

- (void)setDateModified:(CFAbsoluteTime)newTime {
	modifiedDate = newTime;
	
	[dateModifiedString release];
	
	dateModifiedString = [[NSString relativeDateStringWithAbsoluteTime:modifiedDate] retain];
}

- (void)setDateAdded:(CFAbsoluteTime)newTime {
	createdDate = newTime;
	
	[dateCreatedString release];
	
	dateCreatedString = [[NSString relativeDateStringWithAbsoluteTime:createdDate] retain];	
}

- (void)setSelectedRange:(NSRange)newRange {
	//if (!newRange.length) newRange = NSMakeRange(0,0);
	
	//don't save the range if it's invalid, it's equal to the current range, or the entire note is selected
	if ((newRange.location != NSNotFound) && !NSEqualRanges(newRange, selectedRange) && 
		!NSEqualRanges(newRange, NSMakeRange(0, [contentString length]))) {
	//	NSLog(@"saving: old range: %@, new range: %@", NSStringFromRange(selectedRange), NSStringFromRange(newRange));
		selectedRange = newRange;
		[self makeNoteDirtyUpdateTime:NO updateFile:NO];
	}
}

- (NSRange)lastSelectedRange {
	return selectedRange;
}

//these two methods let us get the actual label objects in use by other notes
//they assume that the label string already contains the title of the label object(s); that there is only replacement and not addition
- (void)replaceMatchingLabelSet:(NSSet*)aLabelSet {
    [labelSet minusSet:aLabelSet];
    [labelSet unionSet:aLabelSet];
}

- (void)replaceMatchingLabel:(LabelObject*)aLabel {
    [aLabel retain]; // just in case this is actually the same label
    
    //remove the old label and add the new one; if this is the same one, well, too bad
    [labelSet removeObject:aLabel];
    [labelSet addObject:aLabel];
    [aLabel release];
}

- (void)updateLabelConnectionsAfterDecoding {
	if ([labelString length] > 0) {
		[self updateLabelConnections];
	}
}

- (void)updateLabelConnections {
	return;
	//find differences between previous labels and new ones
	NSMutableSet *oldLabelSet = labelSet;
	NSMutableSet *newLabelSet = [labelString labelSetFromWordsAndContainingNote:self];
	
	//what's left-over
	NSMutableSet *oldLabels = [oldLabelSet mutableCopy];
	[oldLabels minusSet:newLabelSet];
	
	//what wasn't there last time
	NSMutableSet *newLabels = newLabelSet;
	[newLabels minusSet:oldLabelSet];
	
	//update the currently known labels
	[labelSet minusSet:oldLabels];
	[labelSet unionSet:newLabels];
	
	//update our status within the list of all labels, adding or removing from the list and updating the labels where appropriate
	//these end up calling replaceMatchingLabel*
	[delegate note:self didRemoveLabelSet:oldLabels];
	[delegate note:self didAddLabelSet:newLabels];
}

- (void)setLabelString:(NSString*)newLabelString {
	if (newLabelString && ![newLabelString isEqualToString:labelString]) {
		
		[labelString release];
		labelString = [newLabelString copy];
		
		cLabelsFoundPtr = cLabels = replaceString(cLabels, [labelString lowercaseUTF8String]);
		
		[self updateLabelConnections];
		
		[self makeNoteDirtyUpdateTime:YES updateFile:NO];
		
		[delegate note:self attributeChanged:NoteLabelsColumnString];
	}
}

- (NSString*)noteFilePath {
	if (!noteFileRef || IsZeros(noteFileRef, sizeof(FSRef)))
		return nil;
	
	return [NSString pathWithFSRef:noteFileRef];
}

- (void)invalidateFSRef {
	//bzero(&noteFileRef, sizeof(FSRef));
	if (noteFileRef)
		free(noteFileRef);
	noteFileRef = NULL;
}

- (BOOL)writeUsingCurrentFileFormatIfNecessary {
	//if note had been updated via makeNoteDirty and needed file to be rewritten
	if (shouldWriteToFile) {
		return [self writeUsingCurrentFileFormat];
	}
	return NO;
}

- (BOOL)writeUsingCurrentFileFormatIfNonExistingOrChanged {
    BOOL fileWasCreated = NO;
    BOOL fileIsOwned = NO;
	
    if ([delegate createFileIfNotPresentInNotesDirectory:noteFileRefInit(self) forFilename:filename fileWasCreated:&fileWasCreated] != noErr)
		return NO;
    
    if (fileWasCreated) {
		NSLog(@"writing note %@, because it didn't exist", titleString);
		return [self writeUsingCurrentFileFormat];
    }
    
    FSCatalogInfo info;
    if ([delegate fileInNotesDirectory:noteFileRefInit(self) isOwnedByUs:&fileIsOwned hasCatalogInfo:&info] != noErr)
		return NO;
    
    CFAbsoluteTime timeOnDisk, lastTime;
    OSStatus err = noErr;
    if ((err = (UCConvertUTCDateTimeToCFAbsoluteTime(&fileModifiedDate, &lastTime) == noErr)) &&
		(err = (UCConvertUTCDateTimeToCFAbsoluteTime(&info.contentModDate, &timeOnDisk) == noErr))) {
		
		if (lastTime > timeOnDisk) {
			NSLog(@"writing note %@, because it was modified", titleString);
			return [self writeUsingCurrentFileFormat];
		}
    } else {
		NSLog(@"Could not convert dates: %d", err);
    }
    
    return YES;
}

- (BOOL)writeUsingJournal:(WALStorageController*)wal {
    BOOL wroteAllOfNote = [wal writeEstablishedNote:self];
	
    if (wroteAllOfNote) {
		//update formatID to absolutely ensure we don't reload an earlier note back from disk, from text encoding menu, for example
		//currentFormatID = SingleDatabaseFormat;
	} else {
		[delegate noteDidNotWrite:self errorCode:kWriteJournalErr];
	}
    
    return wroteAllOfNote;
}

#if MAC_OS_X_VERSION_MAX_ALLOWED < MAC_OS_X_VERSION_10_4
#define NSDocumentTypeDocumentAttribute @"DocumentType"
#endif

- (BOOL)writeUsingCurrentFileFormat {

    NSData *formattedData = nil;
    NSError *error = nil;
	
    int formatID = [delegate currentNoteStorageFormat];
    switch (formatID) {
		case SingleDatabaseFormat:
			//we probably shouldn't be here
			NSAssert(NO, @"Warning! Tried to write data for an individual note in single-db format!");
			
			return NO;
		case PlainTextFormat:
			
			if (!(formattedData = [[contentString string] dataUsingEncoding:fileEncoding allowLossyConversion:NO])) {
				
				//just make the file unicode and ram it through
				//unicode is probably better than UTF-8, as it's more easily auto-detected by other programs via the BOM
				//but we can auto-detect UTF-8, so what the heck
				[self _setFileEncoding:NSUTF8StringEncoding];
				//maybe we could rename the file file.utf8.txt here
				NSLog(@"promoting to unicode (UTF-8)");
				formattedData = [[contentString string] dataUsingEncoding:fileEncoding allowLossyConversion:YES];
			}
			break;
		case RTFTextFormat:
			formattedData = [contentString RTFFromRange:NSMakeRange(0, [contentString length]) documentAttributes:nil];
			
			break;
		case HTMLFormat:
			//10.4-only
			if (RunningTigerAppKitOrHigher) {
				//export to HTML document here using NSHTMLTextDocumentType;
				formattedData = [contentString dataFromRange:NSMakeRange(0, [contentString length]) 
										  documentAttributes:[NSDictionary dictionaryWithObject:NSHTMLTextDocumentType 
																						 forKey:NSDocumentTypeDocumentAttribute] error:&error];
			} else {
				NSLog(@"Attempted to write a note as HTML on 10.3.9.");
			}
			//our links will always be to filenames, so hopefully we shouldn't have to change anything
			break;
		default:
			NSLog(@"Attempted to write using unknown format ID: %d", formatID);
			//return NO;
    }
    
    if (formattedData) {
		BOOL resetFilename = NO;
		if (!filename || currentFormatID != formatID) {
			//file will (probably) be renamed
			NSLog(@"resetting the file name due to format change: to %d from %d", formatID, currentFormatID);
			[self setFilenameFromTitle];
			resetFilename = YES;
		}
		
		currentFormatID = formatID;
		
		OSStatus err = noErr;
		if ((err = [delegate storeDataAtomicallyInNotesDirectory:formattedData withName:filename destinationRef:noteFileRefInit(self)]) != noErr) {
			NSLog(@"Unable to save note file %@", filename);
			
			[delegate noteDidNotWrite:self errorCode:err];
			return NO;
		}
		//TODO: if writing plaintext set the file encoding with setxattr
		
		if (!resetFilename) {
			NSLog(@"resetting the file name just because.");
			[self setFilenameFromTitle];
		}
		
		FSCatalogInfo info;
		if ([delegate fileInNotesDirectory:noteFileRefInit(self) isOwnedByUs:NULL hasCatalogInfo:&info] != noErr) {
			NSLog(@"Unable to get new modification date of file %@", filename);
			return NO;
		}
		fileModifiedDate = info.contentModDate;
		nodeID = info.nodeID;
		
		//finished writing to file successfully
		shouldWriteToFile = NO;
		
		
		//tell any external editors that we've changed
		
    } else {
		[delegate noteDidNotWrite:self errorCode:kDataFormattingErr];
		NSLog(@"Unable to convert note contents into format %d", formatID);
		return NO;
    }
    
    return YES;
}

- (void)_setFileEncoding:(NSStringEncoding)encoding {
	fileEncoding = encoding;
}

- (BOOL)setFileEncodingAndUpdate:(NSStringEncoding)encoding {
	BOOL updated = YES;
	
	if (encoding != fileEncoding) {
		[self _setFileEncoding:encoding];
		
		if ((updated = [self updateFromFile])) {
			[self makeNoteDirtyUpdateTime:NO updateFile:NO];
			//[[delegate delegate] contentsUpdatedForNote:self];
		}
	}
	
	return updated;
}

- (BOOL)updateFromFile {
    NSMutableData *data = [delegate dataFromFileInNotesDirectory:noteFileRefInit(self) forFilename:filename];
    if (!data) {
		NSLog(@"Couldn't update note from file on disk");
		return NO;
    }
	//TODO: also grab the com.apple.TextEncoding xattr to help getShortLivedStringFromData: in updateFromData: figure out ambiguous cases
	
    if ([self updateFromData:data]) {
		FSCatalogInfo info;
		if ([delegate fileInNotesDirectory:noteFileRefInit(self) isOwnedByUs:NULL hasCatalogInfo:&info] == noErr) {
			fileModifiedDate = info.contentModDate;
			nodeID = info.nodeID;
			
			return YES;
		}
    }
    return NO;
}

- (BOOL)updateFromCatalogEntry:(NoteCatalogEntry*)catEntry {
    NSMutableData *data = [delegate dataFromFileInNotesDirectory:noteFileRefInit(self) forCatalogEntry:catEntry];
    if (!data) {
		NSLog(@"Couldn't update note from file on disk given catalog entry");
		return NO;
    }
    
    if (![self updateFromData:data])
		return NO;
	
	[self setFilename:(NSString*)catEntry->filename withExternalTrigger:YES];
    
    fileModifiedDate = catEntry->lastModified;
    nodeID = catEntry->nodeID;
    return YES;
}

- (BOOL)updateFromData:(NSMutableData*)data {
    
    if (!data) {
		NSLog(@"%@: Data is nil!", NSStringFromSelector(_cmd));
		return NO;
    }
    
    NSMutableString *stringFromData = nil;
    NSMutableAttributedString *attributedStringFromData = nil;
    //interpret based on format; text, rtf, html, etc...
    switch (currentFormatID) {
	case SingleDatabaseFormat:
	    //hmmmmm
		NSAssert(NO, @"Warning! Tried to update data from a note in single-db format!");
	    
	    break;
	case PlainTextFormat:
	    if ((stringFromData = [NSMutableString getShortLivedStringFromData:data ofGuessedEncoding:&fileEncoding])) {
			attributedStringFromData = [[NSMutableAttributedString alloc] initWithString:stringFromData 
																			  attributes:[[GlobalPrefs defaultPrefs] noteBodyAttributes]];
			[stringFromData release];
	    } else {
			NSLog(@"String could not be initialized from data");
	    }
	    
	    break;
	case RTFTextFormat:
	    
		attributedStringFromData = [[NSMutableAttributedString alloc] initWithRTF:data documentAttributes:NULL];
	    break;
	case HTMLFormat:

		attributedStringFromData = [[NSMutableAttributedString alloc] initWithHTML:data documentAttributes:NULL];
		[attributedStringFromData removeAttachments];
		
	    break;
	default:
	    NSLog(@"%@: Unknown format: %d", NSStringFromSelector(_cmd), currentFormatID);
    }
    
    if (!attributedStringFromData) {
		NSLog(@"Couldn't make string out of data for note %@ with format %d", titleString, currentFormatID);
		return NO;
    }
    
	[contentString release];
	contentString = [attributedStringFromData retain];
	[contentString santizeForeignStylesForImporting];
	
	//[contentString setAttributedString:attributedStringFromData];
	contentCacheNeedsUpdate = YES;
    [self updateContentCacheCStringIfNecessary];
	[undoManager removeAllActions];
	
	//[self updateTablePreviewString];
    
    modifiedDate = CFAbsoluteTimeGetCurrent();
    [dateModifiedString release];
    dateModifiedString = [[NSString relativeDateStringWithAbsoluteTime:modifiedDate] retain];
    
    [attributedStringFromData release];
    
    return YES;
}

- (void)moveFileToTrash {
	OSStatus err = noErr;
	if ((err = [delegate moveFileToTrash:noteFileRefInit(self) forFilename:filename]) != noErr) {
		NSLog(@"Couldn't move file to trash: %d", err);
	} else {
		//file's gone! don't assume it's not coming back. if the storage format was not single-db, this note better be removed
		//currentFormatID = SingleDatabaseFormat;
	}
}

- (void)removeFileFromDirectory {
	
	OSStatus err = noErr;
	if ((err = [delegate deleteFileInNotesDirectory:noteFileRefInit(self) forFilename:filename]) != noErr) {
		
		if (err != fnfErr) {
			//what happens if we wanted to undo the deletion? moveFileToTrash will now tell the note that it shouldn't look for the file
			//so it would not be rewritten on re-creation?
			NSLog(@"Unable to delete file %@ (%d); moving to trash instead", filename, err);
			[self moveFileToTrash];
		}
	}
}

- (BOOL)removeUsingJournal:(WALStorageController*)wal {
    return [wal writeRemovalForNote:self];
}

- (void)makeNoteDirtyUpdateTime:(BOOL)updateTime updateFile:(BOOL)updateFile {
	
	if (updateFile)
		shouldWriteToFile = YES;
	//else we don't turn file updating off--we might be overwriting the state of a previous note-dirty message
	
	if (updateTime) {
		modifiedDate = CFAbsoluteTimeGetCurrent();
		
		if ([delegate currentNoteStorageFormat] == SingleDatabaseFormat) {
			//only set if we're not currently synchronizing to avoid re-reading old data
			//this will be updated again when writing to a file, but for now we have the newest version
			//we must do this to allow new notes to be written when switching formats, and for encodingmanager checks
			if (UCConvertCFAbsoluteTimeToUTCDateTime(modifiedDate, &fileModifiedDate) != noErr)
				NSLog(@"Unable to set file modification date from current date");
		}
		
		[dateModifiedString release];
		dateModifiedString = [[NSString relativeDateStringWithAbsoluteTime:modifiedDate] retain];
	}
	
	//queue note to be written
    [delegate scheduleWriteForNote:self];	
	
	//tell delegate that the date modified changed
	//[delegate note:self attributeChanged:NoteDateModifiedColumnString];
	//except we don't want this here, as it will cause unnecessary (potential) re-sorting and updating of list view while typing
	//so expect the delegate to know to schedule the same update itself
}


- (OSStatus)exportToDirectoryRef:(FSRef*)directoryRef withFilename:(NSString*)userFilename usingFormat:(int)storageFormat overwrite:(BOOL)overwrite {
	
	NSData *formattedData = nil;
	NSError *error = nil;
	
	switch (storageFormat) {
		case SingleDatabaseFormat:
			NSAssert(NO, @"Warning! Tried to export data in single-db format!?");
		case PlainTextFormat:
			if (!(formattedData = [[contentString string] dataUsingEncoding:fileEncoding allowLossyConversion:NO]))
				formattedData = [[contentString string] dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:YES];
			break;
		case RTFTextFormat:
			formattedData = [contentString RTFFromRange:NSMakeRange(0, [contentString length]) documentAttributes:nil];
			break;
		case HTMLFormat:
			if (RunningTigerAppKitOrHigher) {
				formattedData = [contentString dataFromRange:NSMakeRange(0, [contentString length]) 
										  documentAttributes:[NSDictionary dictionaryWithObject:NSHTMLTextDocumentType 
																						 forKey:NSDocumentTypeDocumentAttribute] error:&error];
			} else NSLog(@"Attempted to export note as HTML on 10.3.9.");
			break;
		case WordDocFormat:
			formattedData = [contentString docFormatFromRange:NSMakeRange(0, [contentString length]) documentAttributes:nil];
			break;
		case WordXMLFormat:
			if (RunningTigerAppKitOrHigher) {
				formattedData = [contentString dataFromRange:NSMakeRange(0, [contentString length]) 
										  documentAttributes:[NSDictionary dictionaryWithObject:NSWordMLTextDocumentType 
																						 forKey:NSDocumentTypeDocumentAttribute] error:&error];
			} else NSLog(@"Attempted to export note as Word XML on 10.3.9.");
			break;
		default:
			NSLog(@"Attempted to export using unknown format ID: %d", storageFormat);
    }
	if (!formattedData)
		return kDataFormattingErr;
	
	//can use our already-determined filename to write here
	//but what about file names that were the same except for their extension? e.g., .txt vs. .text
	//this will give them the same extension and cause an overwrite
	NSString *newextension = [NotationPrefs pathExtensionForFormat:storageFormat];
	NSString *newfilename = userFilename ? userFilename : [[filename stringByDeletingPathExtension] stringByAppendingPathExtension:newextension];
	//one last replacing, though if the unique file-naming method worked this should be unnecessary
	newfilename = (NSString*)[newfilename stringByReplacingOccurrencesOfString:@":" withString:@"/"];
	
	BOOL fileWasCreated = NO;
	
	FSRef fileRef;
	OSStatus err = FSCreateFileIfNotPresentInDirectory(directoryRef, &fileRef, (CFStringRef)newfilename, (Boolean*)&fileWasCreated);
	if (err != noErr) {
		NSLog(@"FSCreateFileIfNotPresentInDirectory: %d", err);
		return err;
	}
	if (!fileWasCreated && !overwrite) {
		NSLog(@"File already existed!");
		return dupFNErr;
	}
	//yes, the file is probably not on the same volume as our notes directory
	if ((err = FSRefWriteData(&fileRef, BlockSizeForNotation(delegate), [formattedData length], [formattedData bytes], 0, true)) != noErr) {
		NSLog(@"error writing to temporary file: %d", err);
		return err;
    }
			
	return noErr;
}

- (NSRange)nextRangeForWords:(NSArray*)words options:(unsigned)opts range:(NSRange)inRange {
	//opts indicate forwards or backwards, inRange allows us to continue from where we left off
	//return location of NSNotFound and length 0 if none of the words could be found inRange
	
	//an optimization would be to fall back on cached cString if contentsWere7Bit is true, but then we have to handle opts ourselves
	unsigned int i;
	NSString *haystack = [contentString string];
	NSRange nextRange = NSMakeRange(NSNotFound, 0);
	for (i=0; i<[words count]; i++) {
		NSString *word = [words objectAtIndex:i];
		if ([word length] > 0) {
			nextRange = [haystack rangeOfString:word options:opts range:inRange];
			if (nextRange.location != NSNotFound && nextRange.length)
				break;
		}
	}

	return nextRange;
}

force_inline void resetFoundPtrsForNote(NoteObject *note) {
	note->cTitleFoundPtr = note->cTitle;
	note->cContentsFoundPtr = note->cContents;
	note->cLabelsFoundPtr = note->cLabels;	
}

BOOL noteContainsUTF8String(NoteObject *note, NoteFilterContext *context) {
	
    if (!context->useCachedPositions) {
		resetFoundPtrsForNote(note);
    }
	
	char *needle = context->needle;
    
	/* NOTE: strstr in Darwin is heinously, supernaturally optimized; it blows boyer-moore out of the water. 
	implementations on other OSes will need considerably more code in this function. */
	
    if (note->cTitleFoundPtr)
		note->cTitleFoundPtr = strstr(note->cTitleFoundPtr, needle);
    
    if (note->cContentsFoundPtr)
		note->cContentsFoundPtr = strstr(note->cContentsFoundPtr, needle);
    
    if (note->cLabelsFoundPtr)
		note->cLabelsFoundPtr = strstr(note->cLabelsFoundPtr, needle);
        
    return note->cContentsFoundPtr || note->cTitleFoundPtr || note->cLabelsFoundPtr;
}

BOOL noteTitleHasPrefixOfUTF8String(NoteObject *note, const char* fullString, size_t stringLen) {
	return !strncmp(note->cTitle, fullString, stringLen);
}

BOOL noteTitleMatchesUTF8String(NoteObject *note, const char* fullString) {
	return !strcmp(note->cTitle, fullString);
}

- (NSSet*)labelSet {
    return labelSet;
}
/*
- (CFArrayRef)rangesForWords:(NSString*)string inRange:(NSRange)rangeLimit {
	//use cstring caches if note is all 7-bit, as we [REALLY OUGHT TO] be able to assume a 1-to-1 character mapping
	
	if (contentsWere7Bit) {
		char *manglingString = strdup([string UTF8String]);
		char *token, *separators = separatorsForCString(manglingString);
		
		while ((token = strsep(&manglingString, separators))) {
			if (*token != '\0') {
				//find all occurrences of token in cContents and add cfranges to cfmutablearray
			}
		}
	}
}*/

- (NSUndoManager*)undoManager {
    if (!undoManager) {
	undoManager = [[NSUndoManager alloc] init];
	
	id center = [NSNotificationCenter defaultCenter];
	[center addObserver:self selector:@selector(_undoManagerDidChange:)
		       name:NSUndoManagerDidUndoChangeNotification
		     object:undoManager];
	
	[center addObserver:self selector:@selector(_undoManagerDidChange:)
		       name:NSUndoManagerDidRedoChangeNotification
		     object:undoManager];
    }
    
    return undoManager;
}

- (void)_undoManagerDidChange:(NSNotification *)notification {
	[self makeNoteDirtyUpdateTime:YES updateFile:YES];
    //queue note to be synchronized to disk (and network if necessary)
}



@end
