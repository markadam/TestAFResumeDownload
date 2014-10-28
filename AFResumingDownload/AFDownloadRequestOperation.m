// AFDownloadRequestOperation.m
//
// Copyright (c) 2012 Peter Steinberger (http://petersteinberger.com)
// 
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// 
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
// 
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import "AFDownloadRequestOperation.h"
#import "AFURLConnectionOperation.h"
#import <CommonCrypto/CommonDigest.h>
#include <fcntl.h>
#include <unistd.h>

@interface AFURLConnectionOperation (AFInternal)
@property (nonatomic, strong) NSURLRequest *request;
@property (readonly, nonatomic, assign) long long totalBytesRead;
@end

typedef void (^AFURLConnectionProgressiveOperationProgressBlock)(NSInteger bytes, long long totalBytes, long long totalBytesExpected, long long totalBytesReadForFile, long long totalBytesExpectedToReadForFile);

@interface AFDownloadRequestOperation() {
    NSError *_fileError;
}
@property (nonatomic, strong) NSString *tempPath;
@property (assign) long long totalContentLength;
@property (nonatomic, assign) long long totalBytesReadPerDownload;
@property (assign) long long offsetContentLength;
@property (nonatomic, copy) AFURLConnectionProgressiveOperationProgressBlock progressiveDownloadProgress;
@end

@implementation AFDownloadRequestOperation

@synthesize targetPath = _targetPath;
@synthesize tempPath = _tempPath;
@synthesize totalContentLength = _totalContentLength;
@synthesize offsetContentLength = _offsetContentLength;
@synthesize shouldResume = _shouldResume;
@synthesize deleteTempFileOnCancel = _deleteTempFileOnCancel;
@synthesize progressiveDownloadProgress = _progressiveDownloadProgress;
@synthesize totalBytesReadPerDownload;
@synthesize downloadFileIndex = _downloadFileIndex;
#pragma mark - Static

+ (NSString *)cacheFolder {
    static NSString *cacheFolder;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *cacheDir = NSTemporaryDirectory();
        cacheFolder = [cacheDir stringByAppendingPathComponent:kAFNetworkingIncompleteDownloadFolderName];
        
        // ensure all cache directories are there (needed only once)
        NSError *error = nil;
        if(![[NSFileManager new] createDirectoryAtPath:cacheFolder withIntermediateDirectories:YES attributes:nil error:&error]) {
            NSLog(@"Failed to create cache directory at %@", cacheFolder);
        }
    });
    return cacheFolder;
}

// calculates the MD5 hash of a key
+ (NSString *)md5StringForString:(NSString *)string {
    const char *str = [string UTF8String];
    unsigned char r[CC_MD5_DIGEST_LENGTH];
    CC_MD5(str, strlen(str), r);
    return [NSString stringWithFormat:@"%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x",
            r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9], r[10], r[11], r[12], r[13], r[14], r[15]];
}

#pragma mark - Private

- (unsigned long long)fileSizeForPath:(NSString *)path {
    signed long long fileSize = 0;
    NSFileManager *fileManager = [NSFileManager new]; // not thread safe
    if ([fileManager fileExistsAtPath:path]) {
        NSError *error = nil;
        NSDictionary *fileDict = [fileManager attributesOfItemAtPath:path error:&error];
        if (!error && fileDict) {
            fileSize = [fileDict fileSize];
        }
    }
    return fileSize;
}

#pragma mark - NSObject

- (id)initWithRequest:(NSURLRequest *)urlRequest targetPath:(NSString *)targetPath shouldResume:(BOOL)shouldResume {
    if ((self = [super initWithRequest:urlRequest])) {
        NSParameterAssert(targetPath != nil && urlRequest != nil);
        _shouldResume = shouldResume;
        
        self.runLoopModes = [NSSet setWithObject:NSRunLoopCommonModes];
        
        // we assume that at least the directory has to exist on the targetPath
        BOOL isDirectory;
        if(![[NSFileManager defaultManager] fileExistsAtPath:targetPath isDirectory:&isDirectory]) {
            isDirectory = NO;
        }        
        // if targetPath is a directory, use the file name we got from the urlRequest.
        if (isDirectory) {
            NSString *fileName = [urlRequest.URL lastPathComponent];
            _targetPath = [NSString pathWithComponents:[NSArray arrayWithObjects:targetPath, fileName, nil]];
        }else {
            _targetPath = targetPath;
        }
        
        // download is saved into a temporal file and remaned upon completion
        NSString *tempPath = [self tempPath];
        
        // do we need to resume the file?
        BOOL isResuming = NO;
        if (shouldResume) {
            unsigned long long downloadedBytes = [self fileSizeForPath:tempPath];
            if (downloadedBytes > 0) {
                NSMutableURLRequest *mutableURLRequest = [urlRequest mutableCopy];
                NSString *requestRange = [NSString stringWithFormat:@"bytes=%llu-", downloadedBytes];
                [mutableURLRequest setValue:requestRange forHTTPHeaderField:@"Range"];
                self.request = mutableURLRequest;
                isResuming = YES;
            }
        }
        
        // try to create/open a file at the target location
        if (!isResuming) {
            int fileDescriptor = open([tempPath UTF8String], O_CREAT | O_EXCL | O_RDWR, 0666);
            if (fileDescriptor > 0) {
                close(fileDescriptor);
            }
        }
        
        self.outputStream = [NSOutputStream outputStreamToFileAtPath:tempPath append:isResuming];
        
        // if the output stream can't be created, instantly destroy the object.
        if (!self.outputStream) {
            return nil;
        }
    }    
    return self;
}

#pragma mark - Public

- (BOOL)deleteTempFileWithError:(NSError **)error {
    NSFileManager *fileManager = [NSFileManager new];
    BOOL success = YES;
    @synchronized(self) {
        NSString *tempPath = [self tempPath];
        if ([fileManager fileExistsAtPath:tempPath]) {
            success = [fileManager removeItemAtPath:[self tempPath] error:error];
        }
    }
    return success;
}

- (NSString *)tempPath {
    NSString *tempPath = nil;
    if (self.targetPath) {
        NSString *md5URLString = [[self class] md5StringForString:self.targetPath];
        tempPath = [[[self class] cacheFolder] stringByAppendingPathComponent:md5URLString];
    }
    return tempPath;
}


- (void)setProgressiveDownloadProgressBlock:(void (^)(NSInteger bytesRead, long long totalBytesRead, long long totalBytesExpected, long long totalBytesReadForFile, long long totalBytesExpectedToReadForFile))block {
    self.progressiveDownloadProgress = block;
}

#pragma mark - AFURLRequestOperation

- (void)setCompletionBlockWithSuccess:(void (^)(AFHTTPRequestOperation *operation, id responseObject))success
                              failure:(void (^)(AFHTTPRequestOperation *operation, NSError *error))failure
{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-retain-cycles"
    self.completionBlock = ^ {
        NSError *localError = nil;
        if([self isCancelled]) {
            // should we clean up? most likely we don't.
            if (self.isDeletingTempFileOnCancel) {
                [self deleteTempFileWithError:&localError];
                if (localError) {
                    _fileError = localError;
                }
            }
            return;

        // loss of network connections = error set, but not cancel
        }else if(!self.error) {
            // move file to final position and capture error        
            @synchronized(self) {
                [[NSFileManager new] moveItemAtPath:[self tempPath] toPath:_targetPath error:&localError];
                if (localError) {
                    _fileError = localError;
                }
            }
        }
        
        if (self.error) {
            dispatch_async(self.failureCallbackQueue ?: dispatch_get_main_queue(), ^{
                failure(self, self.error);
            });
        } else {
            dispatch_async(self.successCallbackQueue ?: dispatch_get_main_queue(), ^{
                success(self, _targetPath);
            });
        }
    };
#pragma clang diagnostic pop
}

- (NSError *)error {
    if (_fileError) {
        return _fileError;
    } else {
        return [super error];
    }
}

#pragma mark - NSURLConnectionDelegate

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
    [super connection:connection didReceiveResponse:response];
    
    // check if we have the correct response
    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
    if (![httpResponse isKindOfClass:[NSHTTPURLResponse class]]) {
        return;
    }
    
    // check for valid response to resume the download if possible
    long long totalContentLength = self.response.expectedContentLength;
    long long fileOffset = 0;
    if(httpResponse.statusCode == 206) {
        NSString *contentRange = [httpResponse.allHeaderFields valueForKey:@"Content-Range"];
        if ([contentRange hasPrefix:@"bytes"]) {
            NSArray *bytes = [contentRange componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" -/"]];
            if ([bytes count] == 4) {
                fileOffset = [[bytes objectAtIndex:1] longLongValue];
                totalContentLength = [[bytes objectAtIndex:2] longLongValue]; // if this is *, it's converted to 0
            }
        }
    }

    self.totalBytesReadPerDownload = 0;
    self.offsetContentLength = MAX(fileOffset, 0);
    self.totalContentLength = totalContentLength;
    [self.outputStream setProperty:[NSNumber numberWithLongLong:_offsetContentLength] forKey:NSStreamFileCurrentOffsetKey];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data  {
    [super connection:connection didReceiveData:data];

    // track custom bytes read because totalBytesRead persists between pause/resume.
    self.totalBytesReadPerDownload += [data length];

    if (self.progressiveDownloadProgress) {
        self.progressiveDownloadProgress((long long)[data length], self.totalBytesRead, self.response.expectedContentLength,self.totalBytesReadPerDownload + self.offsetContentLength, self.totalContentLength);
    }
}

@end
