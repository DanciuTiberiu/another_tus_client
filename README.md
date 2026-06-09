# Another TUS Client

[![Pub Version](https://img.shields.io/pub/v/another_tus_client)](https://pub.dev/packages/another_tus_client)  
[![Platforms](https://img.shields.io/badge/platforms-web%20%7C%20android%20%7C%20ios%20%7C%20desktop-lightgrey)](https://pub.dev/packages/another_tus_client)

A Dart client for resumable file uploads using the TUS protocol.  
Forked from [tus_client_dart](https://pub.dev/packages/tus_client_dart).

> **tus** is an HTTP‑based protocol for _resumable file uploads_.  
> It enables interruption (intentional or accidental) and later resumption of uploads without needing to restart from the beginning.

---

## Table of Contents

- [Usage Examples](#usage-examples)
  - [1. Creating a Client](#1-creating-a-client)
  - [2. Throttling Bandwidth](#2-throttling-bandwidth)
  - [3. Measuring Upload Speed Against Your Own TUS Server](#3-measuring-upload-speed-against-your-own-tus-server)
  - [4. Starting an Upload](#4-starting-an-upload)
  - [5. Pausing an Upload](#5-pausing-an-upload)
  - [6. Resuming an Upload](#6-resuming-an-upload)
  - [7. Canceling an Upload](#7-canceling-an-upload)
  - [8. Using TusFileStore (Native Platforms)](#8-using-tusfilestore-native-platforms)
  - [9. Using TusIndexedDBStore (Web)](#9-using-tusindexeddbstore-web)
  - [10. File Selection on Web](#10-file-selection-on-web)
  - [11. Using TusUploadManager](#11-using-tusuploadmanager)
  - [12. Persisting Upload Manager State](#12-persisting-upload-manager-state)
- [Maintainers](#maintainers)


## Usage Examples

### 1. Creating a Client

```dart
import 'package:another_tus_client/another_tus_client.dart';
import 'package:cross_file/cross_file.dart';

final file = XFile("/path/to/my/pic.jpg");
final client = TusClient(
  file,  // Must be an XFile
  store: TusMemoryStore(), // Will not persist through device restarts. For persistent URL storage in memory see below
  maxChunkSize: 6 * 1024 * 1024, // 6MB chunks
  retries: 5,
  retryScale: RetryScale.exponential,
  retryInterval: 2,
  debug: true, // Will debug both the store and the client
);
```

### 2. Throttling Bandwidth

The client supports optional bandwidth throttling so your upload doesn't saturate the link (e.g. when uploading a large video on a shared network). Three modes are available:

```dart
// 1. No throttling (default — current behavior)
final client = TusClient(file);

// 2. Use ~30% of the measured link speed
final client = TusClient(
  file,
  throttle: ThrottleOptions.bandwidthFraction(0.3),
);

// 3. Hard cap at 2 MB/s
final client = TusClient(
  file,
  throttle: ThrottleOptions.bytesPerSecond(2 * 1024 * 1024),
);
```

`bandwidthFraction` needs a measured upload speed. The client can do this for you by passing a `SpeedProbe`:

```dart
final client = TusClient(
  file,
  throttle: ThrottleOptions.bandwidthFraction(0.3),
  speedProbe: DefaultSpeedProbe(), // hits eu.httpbin.org / postman-echo.com
);

await client.upload(
  uri: Uri.parse('https://your-tus-server.com/files/'),
  measureUploadSpeed: true, // required for the fraction to take effect
);
```

If no probe runs (or it fails), `bandwidthFraction` falls back to a conservative default of 256 KB/s. You can override that:

```dart
throttle: ThrottleOptions.bandwidthFraction(
  0.3,
  fallbackBytesPerSecond: 512 * 1024, // use 512 KB/s if no speed is known
),
```

When used with `TusUploadManager` (which runs up to `maxConcurrentUploads` in parallel), the throttle is applied **per upload**, not globally — so with `bandwidthFraction(0.3)` and 3 concurrent uploads, the manager can use up to ~90% of the link.

### 3. Measuring Upload Speed Against Your Own TUS Server

If you want the most accurate speed measurement — one that includes your server's auth, processing, and the real network path to it — use `TusServerSpeedProbe`. It does a real POST/PATCH/DELETE cycle against your TUS server and times the PATCH:

```dart
final probe = TusServerSpeedProbe(
  config: TusServerProbeConfig(
    tusServerUrl: Uri.parse('https://your-tus-server.com/files/'),
    headers: {'Authorization': 'Bearer your_token'},
    // Optional: fall back to public echo endpoints if the TUS server
    // is unreachable.
    fallback: DefaultSpeedProbe(),
  ),
);

final client = TusClient(
  file,
  throttle: ThrottleOptions.bandwidthFraction(0.3), // 30% of measured
  speedProbe: probe,
);

await client.upload(
  uri: Uri.parse('https://your-tus-server.com/files/'),
  measureUploadSpeed: true,
);
```

The probe runs **1 silent warmup probe** (to absorb TLS + TCP + auth setup cost) and then **2 measured probes**, keeping the best result. After each measured probe it DELETEs the upload so it doesn't pollute your server's storage.

To compose multiple probes (e.g. TUS first, public echo as last resort):

```dart
final probe = FirstSuccessfulSpeedProbe([
  TusServerSpeedProbe(config: TusServerProbeConfig(
    tusServerUrl: Uri.parse('https://your-tus-server.com/files/'),
  )),
  DefaultSpeedProbe(), // public echo endpoints
]);

final client = TusClient(file, speedProbe: probe);
```

### 4. Starting an Upload

```dart
await client.upload(
  uri: Uri.parse("https://your-tus-server.com/files/"),
  onStart: (TusClient client, Duration? estimate) {
    print("Upload started; estimated time: ${estimate?.inSeconds} seconds");
  },
  onProgress: (double progress, Duration estimate) {
    print("Progress: ${progress.toStringAsFixed(1)}%, estimated time: ${estimate.inSeconds} seconds");
  },
  onComplete: () {
    print("Upload complete!");
    print("File URL: ${client.uploadUrl}");
  },
  headers: {"Authorization": "Bearer your_token"},
  metadata: {"cacheControl": "3600"},
  measureUploadSpeed: true,
  preventDuplicates: true, // NEW: Prevents creating duplicate uploads of the same file
);
```

### 3. Pausing an Upload

Upload will pause after the current chunk finishes. For example:

```dart
print("Pausing upload...");
await client.pauseUpload();
```

### 4. Resuming an Upload

If the upload has been paused, you can resume using:

```dart
// Resume with the same callbacks as original upload
await client.resumeUpload();

// Resume with a new progress callback
await client.resumeUpload(
  onProgress: (progress, estimate) {
    print("New progress handler: $progress%");
  }
);

// Clear the progress callback while keeping others
await client.resumeUpload(
  clearProgressCallback: true
);

// Replace some callbacks and clear others
await client.resumeUpload(
  onComplete: () => print("New completion handler"),
  clearProgressCallback: true
);

// Clear all callbacks
await client.clearAllCallbacks();
await client.resumeUpload();
```

### 5. Canceling an Upload

Cancel the current upload and remove any saved state:

```dart
final result = await client.cancelUpload(); // Returns true when successful
if (result) {
  print("Upload canceled successfully.");
}
```

### 6. Using TusFileStore (Native Platforms)

On mobile/desktop, you can persist the upload progress to the file system.

```dart
import 'package:path_provider/path_provider.dart';
import 'dart:io';

final tempDir = await getTemporaryDirectory();
final tempDirectory = Directory('${tempDir.path}/${file.name}_uploads');
if (!tempDirectory.existsSync()) {
  tempDirectory.createSync(recursive: true);
}

final client = TusClient(
  file,
  store: TusFileStore(tempDirectory),
);
await client.upload(uri: Uri.parse("https://your-tus-server.com/files/"));
```

### 7. Using TusIndexedDBStore (Web)

For web applications, use IndexedDB for persistent upload state:

```dart
import 'package:flutter/foundation.dart' show kIsWeb;

final store = kIsWeb ? TusIndexedDBStore() : TusMemoryStore();

final client = TusClient(
  file,
  store: store,
);
await client.upload(uri: Uri.parse("https://your-tus-server.com/files/"));
```

### 8. File Selection on Web

For web applications, you have two main options for handling files:

#### Option 1: Using Any XFile with Loaded Bytes

```dart
import 'package:file_picker/file_picker.dart';

final result = await FilePicker.platform.pickFiles(
    withData: true, // Load bytes into memory. Works for small files
);

if (result == null) {
    return null;
}

final fileWithBytes = result.files.first.xFile; // This returns an XFile with bytes

// Create client with any XFile that has bytes loaded
final client = TusClient(
  fileWithBytes,  // Any XFile with bytes already loaded
  store: TusMemoryStore(), //This TusMemoryStore doesn't persist on reboots.
);

await client.upload(uri: Uri.parse("https://tus.example.com/files"));
```

#### Option 2: Using pickWebFilesForUpload()

This is a built-in method that will open a file picker on web and convert the files to a streamable XFile using Blob.


```dart
final result = await pickWebFilesForUpload(
    allowMultiple: true,
    acceptedFileTypes: ['*']  
)

if (result == null) {
    return null;
}

// Create client with any XFile that has bytes loaded
final client = TusClient(
  result.first,  // Streaming ready XFile
  store: TusMemoryStore(), 
);

await client.upload(uri: Uri.parse("https://tus.example.com/files"));
```

### 9. Using TusUploadManager

The TusUploadManager provides a convenient way to manage multiple uploads with features like automatic queuing, status tracking, and batch operations.

#### Creating the Upload Manager

```dart
import 'package:another_tus_client/another_tus_client.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

// Create a persistent store for upload state
final store = kIsWeb ? TusIndexedDBStore() : TusFileStore(await getUploadDirectory());

// Initialize the manager
final uploadManager = TusUploadManager(
  serverUrl: Uri.parse("https://your-tus-server.com/files/"),
  store: store,
  maxConcurrentUploads: 3,  // Control how many uploads run simultaneously
  autoStart: true,           // Start uploads as soon as they're added (default)
  measureUploadSpeed: true,  // Estimate upload time
  retries: 3,                // Retry failed uploads 3 times
  retryScale: RetryScale.exponential,
  retryInterval: 2,          // Wait 2, 4, 8 seconds between retries
  preventDuplicates: true,   // Prevent creating duplicate uploads
  debug: true, // Will debug manager, client and store
);
```

#### Adding Files to Upload

```dart
// Add a single file. Returns a custom ID for this upload
final uploadId1 = await uploadManager.addUpload(
  file1,
  metadata: {
    "bucketName": "user_files",
    "cacheControl": "3600",
    "contentType": file1.mimeType ?? "application/octet-stream"
  },
  headers: {
    "x-custom-header": "value"  // Add upload-specific headers
  }
);

// Add another file with different settings
final uploadId2 = await uploadManager.addUpload(
  file2,
  metadata: {"bucketName": "images"}
);
```

#### Listening to Upload Events

```dart
// Listen to upload status changes and progress updates
uploadManager.uploadEvents.listen((UploadEvent event) {
  final upload = event.upload;
  final type = event.eventType;
  print("Upload ID: ${upload.id}");
  print("Event: ${type}"); // start, resume, pause, progress, complete, error, cancel, add
  print("Status: ${upload.status}");  // ready, uploading, paused, completed, failed, cancelled
  print("Progress: ${upload.progress}%");
  print("Estimated time: ${upload.estimate.inSeconds} seconds");
  
  if (upload.status == UploadStatus.completed) {
    print("Upload URL: ${upload.client.uploadUrl}");
  } else if (upload.status == UploadStatus.failed) {
    print("Error: ${upload.error}");
  }
});
```

#### Controlling Individual Uploads

```dart
// Pause a specific upload
await uploadManager.pauseUpload(uploadId1);

// Resume a paused upload
await uploadManager.resumeUpload(uploadId1);

// Cancel an upload
await uploadManager.cancelUpload(uploadId2);

// Check for specific upload
final upload = uploadManager.getUpload(uploadId1);
if (upload != null && upload.status == UploadStatus.paused) {
  // Check if it's resumable
  final isResumable = await upload.client.isResumable();
  print("Can resume: $isResumable");
}
```

#### Batch Operations

```dart
// Pause all active uploads
await uploadManager.pauseAll();

// Resume all paused uploads
await uploadManager.resumeAll();

// Cancel all uploads
await uploadManager.cancelAll();

// Get all uploads
final allUploads = uploadManager.getAllUploads();
print("Total uploads: ${allUploads.length}");
```

#### Cleanup

```dart
// Clean up resources when done
@override
void dispose() {
  uploadManager.dispose();
  super.dispose();
}
```

---

## Maintainers

- [Olivier Beaulieu](https://github.com/olivierb24)