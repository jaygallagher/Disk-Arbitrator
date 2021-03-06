//
//  Disk.m
//  DiskArbitrator
//
//  Created by Aaron Burghardt on 1/10/10.
//  Copyright 2010 Aaron Burghardt. All rights reserved.
//

#import "Disk.h"
#import "AppError.h"
#import <DiskArbitration/DiskArbitration.h>
#import "DiskArbitrationPrivateFunctions.h"
#import <IOKit/kext/KextManager.h>
#include <sys/param.h>
#include <sys/mount.h>


@implementation Disk

@synthesize BSDName;
@synthesize isMounting;
@synthesize rejectedMount;
@synthesize icon;
@synthesize parent;
@synthesize children;
@synthesize mountArgs;
@synthesize mountPath;

+ (void)initialize
{
	InitializeDiskArbitration();
}

+ (NSSet *)keyPathsForValuesAffectingValueForKey:(NSString *)key
{
	if ([key isEqual:@"isMountable"])
		return [NSSet setWithObject:@"diskDescription"];

	if ([key isEqual:@"isMounted"])
		return [NSSet setWithObject:@"diskDescription"];

	if ([key isEqual:@"isEjectable"])
		return [NSSet setWithObject:@"diskDescription"];

	if ([key isEqual:@"isWritable"])
		return [NSSet setWithObject:@"diskDescription"];

	if ([key isEqual:@"isRemovable"])
		return [NSSet setWithObject:@"diskDescription"];

	if ([key isEqual:@"isFileSystemWritable"])
		return [NSSet setWithObject:@"diskDescription"];

	if ([key isEqual:@"icon"])
		return [NSSet setWithObject:@"diskDescription"];

	return [super keyPathsForValuesAffectingValueForKey:key];
}

+ (id)uniqueDiskForDADisk:(DADiskRef)diskRef create:(BOOL)create
{
	for (Disk *disk in uniqueDisks) {
		if (disk.hash == CFHash(diskRef))
			return disk;
	}

	return create ? [[[self.class alloc] initWithDADisk:diskRef shouldCreateParent:YES] autorelease] : nil;
}

- (id)initWithDADisk:(DADiskRef)diskRef shouldCreateParent:(BOOL)shouldCreateParent
{
	NSAssert(diskRef, @"No Disk Arbitration disk provided to initializer.");
	
	self = [super init];

	// Return unique instance
	Disk *uniqueDisk = [Disk uniqueDiskForDADisk:diskRef create:NO];
	if (uniqueDisk) {
		[self release];
		return [uniqueDisk retain];
	}
	
	if (self) {
		disk = CFRetain(diskRef);
		const char *bsdName = DADiskGetBSDName(diskRef);
		BSDName = [[NSString alloc] initWithUTF8String:bsdName ? bsdName : ""];
		children = [NSMutableSet new];
		diskDescription = DADiskCopyDescription(diskRef);
		
//		CFShow(description);

		if (self.isWholeDisk == NO) {
			
			DADiskRef parentRef = DADiskCopyWholeDisk(diskRef);
			if (parentRef) {
				Disk *parentDisk = [Disk uniqueDiskForDADisk:parentRef create:shouldCreateParent];
				if (parentDisk) {
					parent = parentDisk; // weak reference
					[[parent mutableSetValueForKey:@"children"] addObject:self];
				}
				SafeCFRelease(parentRef);
			}
		}
		[uniqueDisks addObject:self];
	}

	return self;
}

- (void)dealloc
{
	SafeCFRelease(disk);
	SafeCFRelease(diskDescription);
	[BSDName release];
	[icon release];
	parent = nil;
	[children release];
	[super dealloc];
}

- (NSUInteger)hash
{
	return CFHash(disk);
}

- (BOOL)isEqual:(id)object
{
	return (CFHash(disk) == [object hash]);
}

- (NSString *)description
{
	return [NSString stringWithFormat:@"<%@ 0x%p %@>", self.class, self, BSDName];
}

- (void)mount
{
	[self mountAtPath:nil withArguments:[NSArray array]];
}

- (void)mountAtPath:(NSString *)path withArguments:(NSArray *)args
{
	NSAssert(self.isMountable, @"Disk isn't mountable.");
	NSAssert(self.isMounted == NO, @"Disk is already mounted.");

	self.isMounting = YES;
	self.mountArgs = args;
	self.mountPath = path;

	Log(LOG_DEBUG, @"%s mount %@ at mountpoint: %@ arguments: %@", __func__, BSDName, path, args.description);

	// ensure arg list is NULL terminated
	id *argv = calloc(args.count + 1, sizeof(id));

	[args getObjects:argv range:NSMakeRange(0, args.count)];

	NSURL *url = path ? [NSURL fileURLWithPath:path.stringByExpandingTildeInPath] : NULL;
	
	DADiskMountWithArguments((DADiskRef) disk, (CFURLRef) url, kDADiskMountOptionDefault,
							 DiskMountCallback, self, (CFStringRef *)argv);

	free(argv);
}

- (void)unmountWithOptions:(NSUInteger)options
{
	NSAssert(self.isMountable, @"Disk isn't mountable.");
	NSAssert(self.isMounted, @"Disk isn't mounted.");
	
	DADiskUnmount((DADiskRef) disk, (DADiskUnmountOptions)options, DiskUnmountCallback, self);
}

- (void)eject
{
	NSAssert1(self.isEjectable, @"Disk is not ejectable: %@", self);
	
	DADiskEject((DADiskRef) disk, kDADiskEjectOptionDefault, DiskEjectCallback, [self retain]); // self is released in DiskEjectCallback
}

- (void)diskDidDisappear
{
	[uniqueDisks removeObject:self];
	[[parent mutableSetValueForKey:@"children"] removeObject:self];

	SafeCFRelease(disk);
	disk = NULL;

	self.parent = nil;
	[children removeAllObjects];
	
	self.rejectedMount = NO;
	self.mountArgs = [NSArray array];
	self.mountPath = nil;
}

- (BOOL)isMountable
{
	CFBooleanRef value = diskDescription ? CFDictionaryGetValue(diskDescription, kDADiskDescriptionVolumeMountableKey) : NULL;
	
	return value ? CFBooleanGetValue(value) : NO;
}

- (BOOL)isMounted
{
	CFStringRef value = diskDescription ? CFDictionaryGetValue(diskDescription, kDADiskDescriptionVolumePathKey) : NULL;
	
	return value ? YES : NO;
}

- (BOOL)isWholeDisk
{
	CFBooleanRef value = diskDescription ? CFDictionaryGetValue(diskDescription, kDADiskDescriptionMediaWholeKey) : NULL;
	
	return value ? CFBooleanGetValue(value) : NO;
}

- (BOOL)isLeaf
{
	CFBooleanRef value = diskDescription ? CFDictionaryGetValue(diskDescription, kDADiskDescriptionMediaLeafKey) : NULL;
	
	return value ? CFBooleanGetValue(value) : NO;
}

- (BOOL)isNetworkVolume
{
	CFBooleanRef value = diskDescription ? CFDictionaryGetValue(diskDescription, kDADiskDescriptionVolumeNetworkKey) : NULL;
	
	return value ? CFBooleanGetValue(value) : NO;
}

- (BOOL)isWritable
{
	CFBooleanRef value = diskDescription ? CFDictionaryGetValue(diskDescription, kDADiskDescriptionMediaWritableKey) : NULL;
	
	return value ? CFBooleanGetValue(value) : NO;
}

- (BOOL)isEjectable
{
	CFBooleanRef value = diskDescription ? CFDictionaryGetValue(diskDescription, kDADiskDescriptionMediaEjectableKey) : NULL;
	
	return value ? CFBooleanGetValue(value) : NO;
}

- (BOOL)isRemovable
{
	CFBooleanRef value = diskDescription ? CFDictionaryGetValue(diskDescription, kDADiskDescriptionMediaRemovableKey) : NULL;
	
	return value ? CFBooleanGetValue(value) : NO;
}

- (BOOL)isHFS
{
	CFStringRef volumeKind = diskDescription ? CFDictionaryGetValue(diskDescription, kDADiskDescriptionVolumeKindKey) : NULL;
	return volumeKind ? CFEqual(CFSTR("hfs"), volumeKind) : NO;
}

- (BOOL)isFileSystemWritable
{
	BOOL retval = NO;
	struct statfs fsstat;
	CFURLRef volumePath;
	UInt8 fsrep[MAXPATHLEN];

	// if the media is not writable, the file system cannot be either
	if (self.isWritable == NO)
		return NO;

	volumePath = CFDictionaryGetValue(diskDescription, kDADiskDescriptionVolumePathKey);
	if (volumePath) {

		if (CFURLGetFileSystemRepresentation(volumePath, true, fsrep, sizeof(fsrep))) {

			if (statfs((char *)fsrep, &fsstat) == 0)
				retval = (fsstat.f_flags & MNT_RDONLY) ? NO : YES;
		}
	}

	return retval;
}

- (void)setDiskDescription:(CFDictionaryRef)desc
{
	NSAssert(desc, @"A NULL disk description is not allowed.");
	
	if (desc != diskDescription) {
		[self willChangeValueForKey:@"diskDescription"];

		SafeCFRelease(diskDescription);
		diskDescription = desc ? CFRetain(desc) : NULL;

		[self didChangeValueForKey:@"diskDescription"];
	}
}

- (CFDictionaryRef)diskDescription
{
	return diskDescription;	
}

- (NSImage *)icon
{
	if (!icon) {
		if (diskDescription) {
			CFDictionaryRef iconRef = CFDictionaryGetValue(diskDescription, kDADiskDescriptionMediaIconKey);
			if (iconRef) {

				CFStringRef identifier = CFDictionaryGetValue(iconRef, CFSTR("CFBundleIdentifier"));
				NSURL *url = [(NSURL *)KextManagerCreateURLForBundleIdentifier(kCFAllocatorDefault, identifier) autorelease];
				if (url) {
					NSString *bundlePath = [url path];

					NSBundle *bundle = [NSBundle bundleWithPath:bundlePath];
					if (bundle) {
						NSString *filename = (NSString *) CFDictionaryGetValue(iconRef, CFSTR("IOBundleResourceFile"));
						NSString *basename = [filename stringByDeletingPathExtension];
						NSString *fileext =  [filename pathExtension];

						NSString *path = [bundle pathForResource:basename ofType:fileext];
						if (path) {
							icon = [[NSImage alloc] initWithContentsOfFile:path];
						}
					}
					else {
						Log(LOG_WARNING, @"Failed to load bundle with URL: %@", [url absoluteString]);
						CFShow(diskDescription);
					}
				}
				else {
					Log(LOG_WARNING, @"Failed to create URL for bundle identifier: %@", (NSString *)identifier);
					CFShow(diskDescription);
				}
			}
		}
	}
	
	return icon;
}

- (int)BSDNameNumber
{
	// Take the BSDName and convert it into a number that can be compared with other disks for sorting.
	// For example, "disk2s1" would become 2 * 1000 + 1 = 2001.
	// If we just compare by the string value itself, then disk10 would come after disk1, instead of disk9.
	NSString *s = self.BSDName;
	int device = 0;
	int slice = 0;
	const int found = sscanf(s.UTF8String, "disk%ds%d", &device, &slice);
	if (found == 0 || device < 0 || slice < 0) {
		NSLog(@"Invalid BSD Name %@", s);
	}
	return (device * 1000) + slice;
}

@end
