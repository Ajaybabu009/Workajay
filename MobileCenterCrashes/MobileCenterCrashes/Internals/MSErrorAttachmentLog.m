#import "MSCrashesUtil.h"
#import "MSErrorAttachmentLogInternal.h"
#import "MSUtility.h"

static NSString *const kMSTextType = @"text/plain";

// API property names.
static NSString *const kMSTypeAttachment = @"error_attachment";
static NSString *const kMSId = @"id";
static NSString *const kMSErrorId = @"error_id";
static NSString *const kMSContentType = @"content_type";
static NSString *const kMSFileName = @"file_name";
static NSString *const kMSData = @"data";

@implementation MSErrorAttachmentLog

- (instancetype)init {
  if ((self = [super init])) {
    self.type = kMSTypeAttachment;
    _attachmentId = MS_UUID_STRING;
  }
  return self;
}

- (instancetype)initWithFilename:(nullable NSString *)filename
                attachmentString:(NSString *)data
                     contentType:(NSString *)contentType {
  if ((self = [self init])) {
    _data = data;
    _contentType = contentType;

    // Generate a filename if none is available.
    _filename = (filename.length > 0) ? filename : [MSCrashesUtil generateFilenameForMimeType:contentType];
  }
  return self;
}

- (instancetype)initWithFilename:(nullable NSString *)filename
                  attachmentData:(NSData *)data
                     contentType:(NSString *)contentType {
  if ((self = [self init])) {

    // Convert NSData to base64 string.
    NSString *dataString = [data base64EncodedStringWithOptions:NSDataBase64EncodingEndLineWithCarriageReturn];
    self = [self initWithFilename:filename attachmentString:dataString contentType:contentType];
  }
  return self;
}

- (instancetype)initWithFilename:(nullable NSString *)filename attachmentText:(NSString *)text {
  if ((self = [self init])) {
    self = [self initWithFilename:filename attachmentString:text contentType:kMSTextType];
  }
  return self;
}

- (NSMutableDictionary *)serializeToDictionary {
  NSMutableDictionary *dict = [super serializeToDictionary];

  // Fill in the dictionary.
  if (self.attachmentId) {
    dict[kMSId] = self.attachmentId;
  }
  if (self.errorId) {
    dict[kMSErrorId] = self.errorId;
  }
  if (self.contentType) {
    dict[kMSContentType] = self.contentType;
  }
  if (self.filename) {
    dict[kMSFileName] = self.filename;
  }
  if (self.data) {
    dict[kMSData] = self.data;
  }
  return dict;
}

- (BOOL)isEqual:(id)object {

  // TODO: We should also check for parent equalty with `![super isEqual:object]` but isEqual is not implemented
  // everywhere.
  if (!object || ![object isKindOfClass:[MSErrorAttachmentLog class]])
    return NO;
  MSErrorAttachmentLog *attachment = (MSErrorAttachmentLog *)object;
  return ((!self.attachmentId && !attachment.attachmentId) || [self.attachmentId isEqualToString:attachment.attachmentId]) &&
         ((!self.errorId && !attachment.errorId) || [self.errorId isEqualToString:attachment.errorId]) &&
         ((!self.contentType && !attachment.contentType) || [self.contentType isEqualToString:attachment.contentType]) &&
         ((!self.filename && !attachment.filename) || [self.filename isEqualToString:attachment.filename]) &&
         ((!self.data && !attachment.data) || [self.data isEqualToString:attachment.data]);
}

- (BOOL)isValid {
  return [super isValid] && self.errorId && self.attachmentId && self.filename && self.data && self.contentType;
}

#pragma mark - NSCoding

- (instancetype)initWithCoder:(NSCoder *)coder {
  self = [super initWithCoder:coder];
  if (self) {
    _attachmentId = [coder decodeObjectForKey:kMSId];
    _errorId = [coder decodeObjectForKey:kMSErrorId];
    _contentType = [coder decodeObjectForKey:kMSContentType];
    _filename = [coder decodeObjectForKey:kMSFileName];
    _data = [coder decodeObjectForKey:kMSData];
  }
  return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
  [super encodeWithCoder:coder];
  [coder encodeObject:self.attachmentId forKey:kMSId];
  [coder encodeObject:self.errorId forKey:kMSErrorId];
  [coder encodeObject:self.contentType forKey:kMSContentType];
  [coder encodeObject:self.filename forKey:kMSFileName];
  [coder encodeObject:self.data forKey:kMSData];
}

#pragma mark - Public Interface

+ (nonnull MSErrorAttachmentLog *)attachmentWithText:(nonnull NSString *)text filename:(nullable NSString *)filename {
  return [[MSErrorAttachmentLog alloc] initWithFilename:filename attachmentText:text];
}

+ (nonnull MSErrorAttachmentLog *)attachmentWithBinaryData:(nonnull NSData *)data
                                                  filename:(nullable NSString *)filename
                                               contentType:(nonnull NSString *)contentType {
  return [[MSErrorAttachmentLog alloc] initWithFilename:filename attachmentData:data contentType:contentType];
}

@end