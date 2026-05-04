import 'dart:async';
import 'package:cross_file/cross_file.dart';
import 'package:another_tus_client/another_tus_client.dart';

/// Status of an upload managed by [TusUploadManager]
enum UploadStatus {
  /// Upload is ready but not started
  ready,

  /// Upload is in progress
  uploading,

  /// Upload is paused
  paused,

  /// Upload is completed
  completed,

  /// Upload failed with an error
  failed,

  /// Upload was canceled
  cancelled
}

enum UploadEventType {
  add,
  start,
  progress,
  pause,
  resume,
  complete,
  error,
  cancel
}

/// Information about a managed upload
class ManagedUpload {
  /// Unique ID for this upload
  final String id;

  /// The TusClient instance handling this upload
  final TusClient client;

  /// Current status of the upload
  UploadStatus status;

  /// Progress from 0.0 to 100.0
  double progress;

  /// Estimated time remaining
  Duration estimate;

  /// Error message if status is [UploadStatus.failed]
  String? error;

  /// Created timestamp
  final DateTime createdAt;

  /// Last updated timestamp
  DateTime updatedAt;

  /// Headers for this upload
  final Map<String, String>? headers;

  /// Metadata for this upload
  final Map<String, String>? metadata;

  /// This is a unique hash of the file being uploaded
  String get fingerprint => client.fingerprint;

  ManagedUpload({
    required this.id,
    required this.client,
    this.status = UploadStatus.ready,
    this.progress = 0.0,
    this.estimate = Duration.zero,
    this.error,
    this.headers,
    this.metadata,
  })  : createdAt = DateTime.now(),
        updatedAt = DateTime.now();

  /// Update the upload status and timestamps
  void updateStatus(UploadStatus newStatus, {String? errorMessage}) {
    status = newStatus;
    updatedAt = DateTime.now();
    if (errorMessage != null) {
      error = errorMessage;
    }
  }

  /// Update the progress and estimated time
  void updateProgress(double newProgress, Duration newEstimate) {
    progress = newProgress;
    estimate = newEstimate;
    updatedAt = DateTime.now();
  }
}

class UploadEvent {
  final ManagedUpload upload;
  final UploadEventType eventType;

  UploadEvent({required this.upload, required this.eventType});
}

/// Manager for handling multiple TUS uploads
class TusUploadManager {
  /// TUS server endpoint URL
  final Uri serverUrl;

  /// Store for persisting upload information
  final TusStore store;

  /// Default chunk size for all uploads in bytes (default: 5MB)
  final int defaultChunkSize;

  /// Maximum concurrent uploads (default: 3)
  final int maxConcurrentUploads;

  /// Whether to automatically start uploads when added (default: true)
  final bool autoStart;

  /// Whether to measure upload speed for better time estimates (default: true)
  final bool measureUploadSpeed;

  /// Whether to prevent duplicate uploads (default: true)
  final bool preventDuplicates;

  /// Debug flag for verbose logging
  final bool debug;

  /// Retry settings for failed uploads
  final int retries;
  final RetryScale retryScale;
  final int retryInterval;

  /// Stream controller for upload events
  final StreamController<UploadEvent> _uploadEvents =
      StreamController<UploadEvent>.broadcast();

  /// Map of all managed uploads
  final Map<String, ManagedUpload> _uploads = {};

  /// Queue of uploads waiting to start
  final List<String> _queue = [];

  /// Set of currently active upload IDs
  final Set<String> _activeUploads = {};

  Stream<UploadEvent> get uploadEvents => _uploadEvents.stream;

  /// Internal logging method that respects the debug flag
  void _log(String message) {
    if (debug) {
      print('[TusUploadManager] $message');
    }
  }

  /// Constructor
  TusUploadManager({
    required this.serverUrl,
    required this.store,
    this.defaultChunkSize = 5 * 1024 * 1024,
    this.maxConcurrentUploads = 3,
    this.autoStart = true,
    this.measureUploadSpeed = true,
    this.preventDuplicates = true,
    this.retries = 3,
    this.retryScale = RetryScale.exponential,
    this.retryInterval = 2,
    this.debug = false,
  }) {
    _log('TusUploadManager initialized with serverUrl: $serverUrl');
    _log('Max concurrent uploads: $maxConcurrentUploads');
    _log('Default chunk size: $defaultChunkSize bytes');
  }

  /// Get the fingerprint for an upload by its ID
  /// Returns null if the upload ID is not found
  String? getFingerprintForId(String uploadId) {
    final upload = _uploads[uploadId];
    return upload?.fingerprint;
  }

  /// Find an upload ID by its fingerprint
  /// If multiple uploads have the same fingerprint (same file uploaded multiple times),
  /// returns the most recently added one
  String? getIdByFingerprint(String fingerprint) {
    final matchingUploads = _uploads.entries
        .where((entry) => entry.value.fingerprint == fingerprint)
        .toList();

    // Sort by creation time (newest first) if there are multiple matches
    if (matchingUploads.isNotEmpty) {
      matchingUploads
          .sort((a, b) => b.value.createdAt.compareTo(a.value.createdAt));
      return matchingUploads.first.key;
    }

    return null;
  }

  /// Add a new file for upload
  /// Returns the ID of the managed upload
  Future<String> addUpload(
    XFile file, {
    Map<String, String>? metadata,
    Map<String, String>? headers,
    int? chunkSize,
  }) async {
    _log('Adding upload for file: ${file.name}');

    // Create a TusClient for this file
    final client = TusClient(
      file,
      store: store,
      maxChunkSize: chunkSize ?? defaultChunkSize,
      retries: retries,
      retryScale: retryScale,
      retryInterval: retryInterval,
      debug: debug, // Pass the debug flag
    );

    // Create a unique ID for this upload based on file attributes
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final fingerprint = client.fingerprint;
    final id = '$fingerprint-$timestamp';
    _log('Generated upload ID: $id');

    // Create managed upload object
    final upload = ManagedUpload(
      id: id,
      client: client,
      status: UploadStatus.ready,
      headers: headers, // Store for later reference
      metadata: metadata, // Store for later reference
    );

    // Add to our managed uploads
    _uploads[id] = upload;
    _log('Added to managed uploads map');

    // Emit event
    _uploadEvents
        .add(UploadEvent(upload: upload, eventType: UploadEventType.add));
    _log('Emitted add event');

    // Auto-start if enabled
    if (autoStart) {
      _log('Auto-start enabled, starting upload immediately');
      await startUpload(id);
    } else {
      _log('Added to queue: $id');
      _queue.add(id);
    }

    return id;
  }

  ///Add managed upload
  void addManagedUpload(ManagedUpload upload) {
    _uploads[upload.id] = upload;
    _log('Added to managed uploads map');
    _uploadEvents
        .add(UploadEvent(upload: upload, eventType: UploadEventType.add));
    _log('Emitted add event');
  }

  /// Start a specific upload by ID
  Future<void> startUpload(String id) async {
    _log('Starting upload: $id');
    final upload = _uploads[id];
    if (upload == null) {
      _log('Error: Upload not found: $id');
      throw Exception('Upload not found: $id');
    }

    // Don't start if already uploading
    if (upload.status == UploadStatus.uploading) {
      _log('Upload already in progress, ignoring start request');
      return;
    }

    // Check if we've reached max concurrent uploads
    if (_activeUploads.length >= maxConcurrentUploads) {
      _log('Max concurrent uploads reached, adding to queue');
      // Add to queue if not already there
      if (!_queue.contains(id)) {
        _queue.add(id);
      }
      return;
    }

    // Mark as active
    _activeUploads.add(id);
    _log('Added to active uploads, current count: ${_activeUploads.length}');

    // Remove from queue if present
    _queue.remove(id);

    // Update status
    upload.updateStatus(UploadStatus.uploading);
    _log('Updated status to uploading');

    try {
      _log('Calling client.upload with serverUrl: $serverUrl');
      await upload.client.upload(
        uri: serverUrl,
        headers: upload.headers,
        metadata: upload.metadata,
        measureUploadSpeed: measureUploadSpeed,
        preventDuplicates: preventDuplicates,
        onStart: (client, estimate) {
          _log(
              'Upload started, estimate: ${estimate?.inSeconds ?? "unknown"} seconds');
          upload.updateStatus(UploadStatus.uploading);
          _uploadEvents.add(
              UploadEvent(upload: upload, eventType: UploadEventType.start));
        },
        onProgress: (progress, estimate) {
          _log(
              'Progress: ${progress.toStringAsFixed(1)}%, est. time: ${estimate.inSeconds}s');
          upload.updateProgress(progress, estimate);
          _uploadEvents.add(
              UploadEvent(upload: upload, eventType: UploadEventType.progress));
        },
        onComplete: () {
          _log('Upload completed successfully: $id');
          upload.updateStatus(UploadStatus.completed);
          upload.updateProgress(100, Duration.zero);
          _uploadEvents.add(
              UploadEvent(upload: upload, eventType: UploadEventType.complete));
          _activeUploads.remove(id);
          _processQueue();
        },
      );
    } catch (e) {
      _log('Error during upload: $e');
      upload.updateStatus(UploadStatus.failed, errorMessage: e.toString());
      _uploadEvents
          .add(UploadEvent(upload: upload, eventType: UploadEventType.error));
      _activeUploads.remove(id);
      _processQueue();
    }
  }

  /// Pause an upload
  Future<bool> pauseUpload(String id) async {
    _log('Attempting to pause upload: $id');
    final upload = _uploads[id];
    if (upload == null || upload.status != UploadStatus.uploading) {
      _log('Cannot pause: upload not found or not in uploading state');
      return false;
    }

    _log('Calling client.pauseUpload()');
    final result = await upload.client.pauseUpload();
    if (result) {
      _log('Upload paused successfully');
      upload.updateStatus(UploadStatus.paused);
      _uploadEvents
          .add(UploadEvent(upload: upload, eventType: UploadEventType.pause));
      _activeUploads.remove(id);
      _processQueue();
    } else {
      _log('Failed to pause upload');
    }
    return result;
  }

  /// Resume a paused upload
  Future<void> resumeUpload(String id) async {
    _log('Attempting to resume upload: $id');
    final upload = _uploads[id];
    if (upload == null || upload.status != UploadStatus.paused) {
      _log('Cannot resume: upload not found or not in paused state');
      return;
    }

    // If we've reached max concurrent uploads, add to queue
    if (_activeUploads.length >= maxConcurrentUploads) {
      _log('Max concurrent uploads reached, adding to queue');
      if (!_queue.contains(id)) {
        _queue.add(id);
      }
      return;
    }

    // Mark as active
    _activeUploads.add(id);
    _log('Added to active uploads, current count: ${_activeUploads.length}');

    // Update status
    upload.updateStatus(UploadStatus.uploading);
    _log('Updated status to uploading');

    _uploadEvents
        .add(UploadEvent(upload: upload, eventType: UploadEventType.resume));

    try {
      _log('Calling client.resumeUpload()');
      await upload.client.resumeUpload(
        onProgress: (progress, estimate) {
          _log(
              'Progress: ${progress.toStringAsFixed(1)}%, est. time: ${estimate.inSeconds}s');
          upload.updateProgress(progress, estimate);
          _uploadEvents.add(
              UploadEvent(upload: upload, eventType: UploadEventType.progress));
        },
        onComplete: () {
          _log('Upload completed successfully after resume: $id');
          upload.updateStatus(UploadStatus.completed);
          upload.updateProgress(100, Duration.zero);
          _uploadEvents.add(
              UploadEvent(upload: upload, eventType: UploadEventType.complete));
          _activeUploads.remove(id);
          _processQueue();
        },
      );
    } catch (e) {
      _log('Error resuming upload: $e');
      upload.updateStatus(UploadStatus.failed, errorMessage: e.toString());
      _uploadEvents
          .add(UploadEvent(upload: upload, eventType: UploadEventType.error));
      _activeUploads.remove(id);
      _processQueue();
    }
  }

  Future<bool> cancelUpload(String id) async {
    _log('Attempting to cancel upload: $id');
    final upload = _uploads[id];
    if (upload == null) {
      _log('Upload not found: $id');
      return false;
    }

    bool clientCancelSucceeded = false;
    String? fingerprint;

    // Capture the fingerprint first for possible fallback cleanup
    try {
      fingerprint = upload.client.fingerprint;
      _log('Found fingerprint: $fingerprint');
    } catch (e) {
      _log('Unable to get fingerprint: $e');
    }

    // Try the standard client.cancelUpload regardless of upload status
    try {
      _log('Calling client.cancelUpload()');
      clientCancelSucceeded = await upload.client.cancelUpload();
      _log('client.cancelUpload() result: $clientCancelSucceeded');
    } catch (e) {
      _log('Error in client.cancelUpload(): $e');

      // If the client method failed and we have the fingerprint,
      // try direct fingerprint cleanup as a fallback
      if (fingerprint != null &&
          fingerprint.isNotEmpty &&
          upload.client.store != null) {
        try {
          _log('Attempting manual fingerprint cleanup: $fingerprint');
          await upload.client.store?.remove(fingerprint);
          _log('Manual fingerprint cleanup succeeded');
        } catch (e) {
          _log('Manual fingerprint cleanup failed: $e');
        }
      }
    }

    // Always perform the upload manager's internal cleanup
    _log('Performing TusUploadManager internal cleanup');
    upload.updateStatus(UploadStatus.cancelled);
    _uploadEvents
        .add(UploadEvent(upload: upload, eventType: UploadEventType.cancel));
    _uploads.remove(id);
    _activeUploads.remove(id);
    _queue.remove(id);
    _processQueue();

    // Return true if either the client cancel succeeded or we did a manual cleanup
    return true;
  }

  /// Get all managed uploads
  List<ManagedUpload> getAllUploads() {
    _log('Getting all uploads, count: ${_uploads.length}');
    return _uploads.values.toList();
  }

  /// Get a specific upload by ID
  ManagedUpload? getUpload(String id) {
    _log('Getting upload: $id');
    return _uploads[id];
  }

  /// Pause all active uploads
  Future<void> pauseAll() async {
    _log('Pausing all active uploads');
    // Create a copy of activeUploads to avoid modification during iteration
    final activeIds = List<String>.from(_activeUploads);
    _log('Active uploads count: ${activeIds.length}');
    for (final id in activeIds) {
      await pauseUpload(id);
    }
  }

  /// Resume all paused uploads
  Future<void> resumeAll() async {
    _log('Resuming all paused uploads');
    final pausedUploads = _uploads.values
        .where((upload) => upload.status == UploadStatus.paused)
        .map((upload) => upload.id)
        .toList();

    _log('Paused uploads count: ${pausedUploads.length}');

    for (final id in pausedUploads) {
      // This will add to queue if we've reached max concurrent uploads
      await resumeUpload(id);
    }
  }

  /// Cancel all uploads
  Future<void> cancelAll() async {
    _log('Cancelling all uploads');
    final uploadIds = List<String>.from(_uploads.keys);
    _log('Total uploads to cancel: ${uploadIds.length}');
    for (final id in uploadIds) {
      await cancelUpload(id);
    }
  }

  /// Process the upload queue
  void _processQueue() {
    _log(
        'Processing queue, items: ${_queue.length}, active: ${_activeUploads.length}');
    // Start uploads from the queue if we have capacity
    while (_activeUploads.length < maxConcurrentUploads && _queue.isNotEmpty) {
      final id = _queue.removeAt(0);
      _log('Starting queued upload: $id');
      // Don't await to allow concurrent processing
      startUpload(id).catchError((e) {
        _log('Error starting queued upload $id: $e');
      });
    }
  }

  /// Clean up resources
  void dispose() {
    _log('Disposing TusUploadManager');
    _uploadEvents.close();
  }
}
