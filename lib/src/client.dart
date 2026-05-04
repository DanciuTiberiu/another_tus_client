import 'dart:async';
import 'dart:developer';
import 'dart:math' show min;
import 'dart:typed_data' show Uint8List, BytesBuilder;

import 'package:cross_file/cross_file.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:speed_test_dart/speed_test_dart.dart';
import 'package:universal_io/io.dart';

import 'exceptions.dart';
import 'package:another_tus_client/src/retry_scale.dart';
import 'package:another_tus_client/src/tus_client_base.dart';

import 'package:crypto/crypto.dart';
import 'dart:convert';

/// This class is used for creating or resuming uploads.
class TusClient extends TusClientBase {
  /// Create a new TusClient
  ///
  /// [file] An XFile instance representing the file to upload
  /// [store] Optional store for resumable uploads
  /// [maxChunkSize] Maximum size of chunks for upload (default: 512KB)
  /// [retries] Number of retries for failed uploads
  /// [retryScale] Scaling policy for retry intervals
  /// [retryInterval] Base interval between retries in milliseconds
  /// [debug] Optional debug flag for verbose output
  TusClient(
    XFile super.file, {
    super.store,
    super.maxChunkSize = 512 * 1024,
    super.retries = 0,
    super.retryScale = RetryScale.constant,
    super.retryInterval = 0,
    this.debug = false,
  }) : _file = file {

    if (store != null && debug) {
      // Only enable debug on store if client has debugging enabled
      store?.setDebug(true);
    }

    _fingerprint = generateFingerprint();
    _log('TusClient initialized with file: ${_file.name}');
    _log('Fingerprint generated: $_fingerprint');
  }

  /// Debug flag to enable verbose logging
  final bool debug;

  final XFile _file;

  /// The file being uploaded
  XFile get file => _file;

  /// Override this method to use a custom HTTP Client
  http.Client getHttpClient() => http.Client();

  int _actualRetry = 0;

  // Store the callbacks
  Function(double, Duration)? _onProgress;
  Function(TusClient, Duration?)? _onStart;
  Function()? _onComplete;

  /// Internal logging method that respects the debug flag
  void _log(String message) {
    if (debug) {
      log('[TusClient] $message');
    }
  }

  /// Create a new [upload] throwing [ProtocolException] on server error
  Future<void> createUpload() async {
    _log('Creating new upload');
    try {
      if (_file.length is Function) {
        // For web when length is a function that returns Future<int>
        try {
          _log('Getting file size via function call (web)');
          _fileSize = await (_file.length as dynamic)();
          _log('File size determined: $_fileSize bytes');
        } catch (e) {
          _log("Error getting file size from function: $e");
          _fileSize = 0;
        }
      } else {
        // For mobile/desktop when length is a direct value
        _fileSize = _file.length as int?;
        _log('File size determined: $_fileSize bytes');
      }

      if (_fileSize == 0) {
        _log('File size is 0, reading bytes to determine actual size');
        final content = await _file.readAsBytes();
        _fileSize = content.length;
        _log('File size from bytes: $_fileSize');
      }

      final client = getHttpClient();
      final createHeaders = Map<String, String>.from(headers ?? {})
        ..addAll({
          "Tus-Resumable": tusVersion,
          "Upload-Metadata": _uploadMetadata ?? "",
          "Upload-Length": "$_fileSize",
        });

      _log('Request headers: $createHeaders');
      final _url = url;

      if (_url == null) {
        _log('Error: URL is null');
        throw ProtocolException('Error in request, URL is incorrect');
      }

      _log('Sending POST request to $_url');
      final response = await client.post(_url, headers: createHeaders);
      _log('Response status code: ${response.statusCode}');

      if (!(response.statusCode >= 200 && response.statusCode < 300) &&
          response.statusCode != 404) {
        _log('Unexpected status code: ${response.statusCode}');
        throw ProtocolException(
            "Unexpected Error while creating upload", response.statusCode);
      }

      String urlStr = response.headers["location"] ?? "";
      _log('Location header: $urlStr');

      if (urlStr.isEmpty) {
        _log('Error: Empty location header');
        throw ProtocolException(
            "Missing upload Uri in response for creating upload");
      }

      _uploadUrl = _parseUrl(urlStr);
      _log('Parsed upload URL: $_uploadUrl');

      _log('Storing upload URL in store');
      await store?.set(_fingerprint, _uploadUrl as Uri);
      _log('Upload created successfully');
    } catch (e) {
      _log('Error creating upload: $e');
      if (e is ProtocolException) rethrow;
      throw Exception('Cannot initiate file upload: $e');
    }
  }

  /// Checks if upload can be resumed, including verification with the server.
  /// Returns true if the upload exists both in the local store and on the server.
  Future<bool> isResumable() async {
    _log('Checking if upload is resumable');
    try {
      // Early return if resuming is not enabled
      if (!resumingEnabled) {
        _log('Resuming not enabled, returning false');
        return false;
      }

      // Get file size if not already set
      if (_fileSize == null) {
        _log('File size not set, determining size');
        _fileSize = await _getFileSize();
        _log('File size: $_fileSize bytes');
      }

      // Check if we have a stored upload URL
      _log('Checking for stored URL with fingerprint: $_fingerprint');
      final storedUrl = await store?.get(_fingerprint);
      if (storedUrl == null) {
        _log('No stored URL found');
        return false;
      }
      _log('Found stored URL: $storedUrl');

      // Temporarily use the stored URL to verify with the server
      _log('Verifying upload exists on server');
      final uploadExists = await _verifyUploadExists(storedUrl);
      _log('Upload exists on server: $uploadExists');

      return uploadExists;
    } catch (e) {
      _log('Error checking resumability: $e');
      return false;
    }
  }

  /// Helper method to get the file size consistently across platforms
  Future<int> _getFileSize() async {
    _log('Getting file size');
    try {
      if (_file.length is Function) {
        // For web when length is a function that returns Future<int>
        _log('Getting file size via function (web)');
        return await (_file.length as dynamic)();
      } else {
        // For mobile/desktop when length is a direct value
        _log('Getting file size directly (mobile/desktop)');
        return _file.length as int;
      }
    } catch (e) {
      _log('Error getting file size: $e');
      // If there's an error, try reading file content
      _log('Falling back to reading bytes for size');
      final content = await _file.readAsBytes();
      _log('Size from bytes: ${content.length}');
      return content.length;
    }
  }

  /// Helper method to verify an upload exists on the server without changing client state
  Future<bool> _verifyUploadExists(Uri uploadUrl) async {
    _log('Verifying upload exists at URL: $uploadUrl');
    try {
      final client = getHttpClient();
      final verifyHeaders = Map<String, String>.from(headers ?? {})
        ..addAll({
          "Tus-Resumable": tusVersion,
        });

      _log('Sending HEAD request with headers: $verifyHeaders');
      final response = await client.head(uploadUrl, headers: verifyHeaders);
      _log('Response status code: ${response.statusCode}');
      _log('Response headers: ${response.headers}');

      // Check for successful response (2xx) and Upload-Offset header
      if (response.statusCode >= 200 && response.statusCode < 300) {
        final uploadOffset = response.headers["upload-offset"];
        _log('Upload-Offset header: $uploadOffset');
        return uploadOffset != null && uploadOffset.isNotEmpty;
      }

      _log('Verification failed with status code: ${response.statusCode}');
      return false;
    } catch (e) {
      _log('Error verifying upload existence: $e');
      return false;
    }
  }

  Future<void> setUploadTestServers() async {
    _log('Setting up upload test servers');
    final tester = SpeedTestDart();

    try {
      _log('Getting speed test settings');
      final settings = await tester.getSettings();
      final servers = settings.servers;
      _log('Found ${servers.length} speed test servers');

      _log('Finding best servers');
      bestServers = await tester.getBestServers(
        servers: servers,
      );
      _log('Selected ${bestServers?.length ?? 0} best servers');
    } catch (e) {
      _log('Error setting up test servers: $e');
      bestServers = null;
    }
  }

  Future<void> uploadSpeedTest() async {
    _log('Running upload speed test');
    final tester = SpeedTestDart();

    // If bestServers are null or they are empty, we will not measure upload speed
    // as it wouldn't be accurate at all
    if (bestServers == null || (bestServers?.isEmpty ?? true)) {
      _log('No best servers available, skipping speed test');
      uploadSpeed = null;
      return;
    }

    try {
      _log('Testing upload speed with ${bestServers?.length ?? 0} servers');
      uploadSpeed = await tester.testUploadSpeed(servers: bestServers ?? []);
      _log('Upload speed: ${uploadSpeed ?? "unknown"} Mbps');
    } catch (e) {
      _log('Error testing upload speed: $e');
      uploadSpeed = null;
    }
  }

  /// Start or resume an upload in chunks of [maxChunkSize] throwing
  /// [ProtocolException] on server error
  Future<void> upload({
    Function(double, Duration)? onProgress,
    Function(TusClient, Duration?)? onStart,
    Function()? onComplete,
    required Uri uri,
    Map<String, String>? metadata = const {},
    Map<String, String>? headers = const {},
    bool measureUploadSpeed = false,
    bool preventDuplicates = true,
  }) async {
    _log('Starting upload process to $uri');
    _log(
        'Parameters: measureUploadSpeed=$measureUploadSpeed, preventDuplicates=$preventDuplicates');

    setUploadData(uri, headers, metadata);
    _log('Upload data set');

    // Check for duplicates if requested
    if (preventDuplicates) {
      _log('Checking for duplicate uploads');
      final (exists, canResume) = await checkExistingUpload();
      _log('Existing upload check: exists=$exists, canResume=$canResume');

      if (exists && !canResume) {
        _log('Upload exists but cannot be resumed');
        throw ProtocolException(
            'An upload with the same fingerprint exists but cannot be resumed. '
            'If you wish to force a new upload, set preventDuplicates to false.');
      }
    }

    _log('Checking if upload is resumable');
    final _isResumable = await isResumable();
    _log('Is resumable: $_isResumable');

    // Save the callbacks for possible resume.
    _onProgress = onProgress;
    _onComplete = onComplete;
    _onStart = onStart;
    _log('Callbacks saved');

    if (measureUploadSpeed) {
      _log('Measuring upload speed');
      await setUploadTestServers();
      await uploadSpeedTest();
    }

    if (!_isResumable) {
      _log('Upload not resumable, creating new upload');
      await createUpload();
    } else {
      _log('Upload is resumable, using existing upload');
    }

    // get offset from server
    _log('Getting current offset from server');
    _offset = await _getOffset();
    _log('Current offset: $_offset bytes');

    // Save the file size as an int in a variable to avoid having to call
    int totalBytes = _fileSize as int;
    _log('Total bytes to upload: $totalBytes');

    // File existence check for non-web platforms before starting upload
    if (!kIsWeb && _file.path.isNotEmpty) {
      _log('Checking file existence: ${_file.path}');
      try {
        final file = File(_file.path);
        if (!file.existsSync()) {
          _log('Error: File not found');
          throw Exception("Cannot find file ${_file.path.split('/').last}");
        }
        _log('File exists');
      } catch (e) {
        _log('Error accessing file: $e');
        throw Exception("Cannot access file ${_file.path.split('/').last}: $e");
      }
    }

    // We start a stopwatch to calculate the upload speed
    _log('Starting upload stopwatch');
    final uploadStopwatch = Stopwatch()..start();

    // start upload
    _log('Initializing HTTP client');
    final client = getHttpClient();

    if (onStart != null) {
      _log('Calling onStart callback');
      Duration? estimate;
      if (uploadSpeed != null) {
        final _workedUploadSpeed = uploadSpeed! * 1000000;
        _log('Calculated upload speed: $_workedUploadSpeed bytes/s');

        estimate = Duration(
          seconds: (totalBytes / _workedUploadSpeed).round(),
        );
        _log('Estimated upload time: ${estimate.inSeconds} seconds');
      }
      // The time remaining to finish the upload
      onStart(this, estimate);
    }

    _log('Starting upload loop');
    while (!_pauseUpload && _offset < totalBytes) {
      _log(
          'Upload chunk: offset=$_offset, chunk=${min(maxChunkSize, totalBytes - _offset)} bytes');

      // File existence check for non-web platforms before each chunk
      if (!kIsWeb && _file.path.isNotEmpty) {
        try {
          final file = File(_file.path);
          if (!file.existsSync()) {
            _log('Error: File no longer exists');
            throw Exception("Cannot find file ${_file.path.split('/').last}");
          }
        } catch (e) {
          _log('Error accessing file during chunk upload: $e');
          throw Exception(
              "Cannot access file ${_file.path.split('/').last}: $e");
        }
      }

      final uploadHeaders = Map<String, String>.from(headers ?? {})
        ..addAll({
          "Tus-Resumable": tusVersion,
          "Upload-Offset": "$_offset",
          "Content-Type": "application/offset+octet-stream"
        });
      _log('Upload headers: $uploadHeaders');

      await _performUpload(
        onComplete: onComplete,
        onProgress: onProgress,
        uploadHeaders: uploadHeaders,
        client: client,
        uploadStopwatch: uploadStopwatch,
        totalBytes: totalBytes,
      );
    }

    if (_pauseUpload) {
      _log('Upload paused at offset: $_offset / $totalBytes bytes');
    } else {
      _log('Upload loop completed');
    }
  }

  /// Checks if an upload with the same fingerprint already exists and can be resumed
  /// Returns a tuple of (exists, canResume)
  Future<(bool, bool)> checkExistingUpload() async {
    _log('Checking if upload with fingerprint $_fingerprint exists');

    // Generate the fingerprint if not already set
    if (_fingerprint.isEmpty) {
      _log('Fingerprint empty, generating new fingerprint');
      _fingerprint = generateFingerprint();
      _log('Generated fingerprint: $_fingerprint');
    }

    // Check if resumable
    _log('Checking if upload is resumable');
    final canResume = await isResumable();
    _log('Resumable check result: $canResume');

    // If we can resume, return (true, true)
    if (canResume) {
      _log('Upload exists and can be resumed');
      return (true, true);
    }

    // If not resumable but exists in store, return (true, false)
    _log('Checking if exists in store');
    final existsInStore = await store?.get(_fingerprint) != null;
    _log('Exists in store: $existsInStore');

    if (existsInStore) {
      // Clean up the non-resumable but existing upload
      _log('Upload exists in store but cannot be resumed, removing');
      await store?.remove(_fingerprint);
      return (true, false);
    }

    // Doesn't exist
    _log('Upload does not exist');
    return (false, false);
  }

  Future<void> _performUpload({
    Function(double, Duration)? onProgress,
    Function()? onComplete,
    required Map<String, String> uploadHeaders,
    required http.Client client,
    required Stopwatch uploadStopwatch,
    required int totalBytes,
  }) async {
    _log(
        'Performing upload chunk: offset=$_offset, maxChunkSize=$maxChunkSize');

    try {
      _log('Creating PATCH request to ${_uploadUrl}');
      final request = http.Request("PATCH", _uploadUrl as Uri)
        ..headers.addAll(uploadHeaders);

      _log('Reading data chunk');
      request.bodyBytes = await _getData();
      _log('Data chunk size: ${request.bodyBytes.length} bytes');

      _log('Sending PATCH request');
      _response = await client.send(request);
      _log('Response status: ${_response?.statusCode}');

      if (_response != null) {
        _log('Processing response stream');
        _response?.stream.listen(
          (newBytes) {
            if (_actualRetry != 0) {
              _log('Reset retry counter');
              _actualRetry = 0;
            }
          },
          onDone: () {
            _log('Response stream completed');
            if (onProgress != null && !_pauseUpload) {
              // Total byte sent
              final totalSent = _offset + maxChunkSize;
              _log('Total sent: $totalSent / $totalBytes bytes');

              double _workedUploadSpeed = 1.0;

              // If upload speed != null, it means it has been measured
              if (uploadSpeed != null) {
                // Multiplied by 10^6 to convert from Mb/s to b/s
                _workedUploadSpeed = uploadSpeed! * 1000000;
                _log(
                    'Using measured upload speed: $_workedUploadSpeed bytes/s');
              } else {
                _workedUploadSpeed =
                    totalSent / uploadStopwatch.elapsedMilliseconds;
                _log('Calculated upload speed: $_workedUploadSpeed bytes/s');
              }

              // The data that hasn't been sent yet
              final remainData = totalBytes - totalSent;
              final safeRemainData = remainData < 0 ? 0 : remainData;
              _log('Remaining data: $safeRemainData bytes');

              // The time remaining to finish the upload, clamped to 0
              final estimate = Duration(
                seconds: (safeRemainData / _workedUploadSpeed).round(),
              );
              _log('Estimated time remaining: ${estimate.inSeconds} seconds');

              final progress = totalSent / totalBytes * 100;
              _log('Progress: ${progress.toStringAsFixed(2)}%');

              try {
                _log('Calling onProgress callback');
                onProgress((progress).clamp(0, 100), estimate);
              } catch (e) {
                _log("Error in onProgress callback: $e");
              }

              _actualRetry = 0;
            }
          },
        );

        // check if correctly uploaded
        if (!(_response!.statusCode >= 200 && _response!.statusCode < 300)) {
          _log('Error response: ${_response!.statusCode}');
          throw ProtocolException(
            "Error while uploading file",
            _response!.statusCode,
          );
        }

        _log('Parsing offset from response headers: ${_response!.headers}');
        int? serverOffset = _parseOffset(_response!.headers["upload-offset"]);
        if (serverOffset == null) {
          _log('Error: Missing upload offset header');
          throw ProtocolException(
              "Response to PATCH request contains no or invalid Upload-Offset header");
        }

        _log('Server reported offset: $serverOffset, local offset: $_offset');
        if (_offset != serverOffset) {
          _log('Error: Offset mismatch');
          throw ProtocolException(
              "Response contains different Upload-Offset value ($serverOffset) than expected ($_offset)");
        }

        if (_offset == totalBytes && !_pauseUpload) {
          _log('Upload complete! Total bytes: $totalBytes');
          await onCompleteUpload();
          if (onComplete != null) {
            _log('Calling onComplete callback');
            try {
              onComplete();
            } catch (e) {
              _log("Error in onComplete callback: $e");
            }
          }
        }
      } else {
        _log('Error: null response');
        throw ProtocolException("Error getting Response from server");
      }
    } catch (e) {
      _log('Error during upload: $e');
      if (_actualRetry >= retries) {
        _log('Max retries exceeded, throwing error');
        rethrow;
      }

      final waitInterval = retryScale.getInterval(
        _actualRetry,
        retryInterval,
      );
      _actualRetry += 1;
      _log(
          'Retry attempt $_actualRetry after ${waitInterval.inMilliseconds}ms');

      await Future.delayed(waitInterval);
      _log('Retrying upload');

      return await _performUpload(
        onComplete: onComplete,
        onProgress: onProgress,
        uploadHeaders: uploadHeaders,
        client: client,
        uploadStopwatch: uploadStopwatch,
        totalBytes: totalBytes,
      );
    }
  }

  /// Pause the current upload
  Future<bool> pauseUpload() async {
    _log('Pausing upload');
    try {
      _pauseUpload = true;
      _log('Pausing response stream');
      await _response?.stream.timeout(Duration.zero);
      _log('Upload paused');
      return true;
    } catch (e) {
      _log('Error pausing upload: $e');
      throw Exception("Error pausing upload");
    }
  }

  /// Resume a previously paused upload with intelligent callback handling
  ///
  /// Callback behavior:
  /// - If a callback is provided, it replaces the previous one
  /// - if a clear value is set to false, the callback will be removed, even if
  ///   a new one was passed.
  Future<void> resumeUpload({
    Function(double, Duration)? onProgress,
    bool clearProgressCallback = false,
    Function(TusClient, Duration?)? onStart,
    bool clearStartCallback = false,
    Function()? onComplete,
    bool clearCompleteCallback = false,
  }) async {
    _log('Resuming upload with callbacks management');

    // Handle progress callback
    if (clearProgressCallback) {
      // Clear flag takes precedence
      _log('Clearing progress callback');
      _onProgress = null;
    } else if (onProgress != null) {
      // Otherwise use provided callback
      _log('Setting new progress callback');
      _onProgress = onProgress;
    }

    // Handle start callback
    if (clearStartCallback) {
      _log('Clearing start callback');
      _onStart = null;
    } else if (onStart != null) {
      _log('Setting new start callback');
      _onStart = onStart;
    }

    // Handle complete callback
    if (clearCompleteCallback) {
      _log('Clearing complete callback');
      _onComplete = null;
    } else if (onComplete != null) {
      _log('Setting new complete callback');
      _onComplete = onComplete;
    }

    // Continue with the upload resumption
    _log('Calling internal resume logic');
    await _performResume();
  }

  /// Helper method to clear all callbacks at once
  /// without calling resume
  void clearAllCallbacks() {
    _log('Clearing all callbacks');
    _onProgress = null;
    _onStart = null;
    _onComplete = null;
  }

  /// Internal method to handle the actual resumption logic
  Future<void> _performResume() async {
    _log('Performing resume operation');

    // Don't resume if already in progress or no upload URL
    if (!_pauseUpload || _uploadUrl == null) {
      _log('Cannot resume: pauseUpload=$_pauseUpload, uploadUrl=$_uploadUrl');
      return;
    }

    // Reset pause flag
    _log('Resetting pause flag');
    _pauseUpload = false;

    // Verify the upload exists on the server
    _log('Verifying upload exists on server');
    if (!await _verifyUploadExists(_uploadUrl!)) {
      _log('Error: Upload no longer exists on server');
      throw ProtocolException('The upload no longer exists on the server');
    }

    // Get the current offset from the server
    _log('Getting current offset from server');
    _offset = await _getOffset();
    _log('Current offset: $_offset');

    // Start a stopwatch for speed calculation
    _log('Starting upload stopwatch');
    final uploadStopwatch = Stopwatch()..start();

    // Notify about resuming the upload
    if (_onStart != null) {
      _log('Calling onStart callback');
      Duration? estimate;
      if (uploadSpeed != null && _fileSize != null) {
        final _workedUploadSpeed = uploadSpeed! * 1000000;
        _log('Upload speed: $_workedUploadSpeed bytes/s');

        estimate = Duration(
          seconds: ((_fileSize! - _offset) / _workedUploadSpeed).round(),
        );
        _log('Estimated time: ${estimate.inSeconds} seconds');
      }
      _onStart!(this, estimate);
    }

    // Continue the upload process
    _log('Initializing HTTP client for resume');
    final client = getHttpClient();
    int totalBytes = _fileSize ?? 0;
    _log('Total bytes: $totalBytes, current offset: $_offset');

    _log('Starting resume upload loop');
    while (!_pauseUpload && _offset < totalBytes) {
      _log('Uploading chunk from offset $_offset');
      final uploadHeaders = Map<String, String>.from(headers ?? {})
        ..addAll({
          "Tus-Resumable": tusVersion,
          "Upload-Offset": "$_offset",
          "Content-Type": "application/offset+octet-stream"
        });
      _log('Headers: $uploadHeaders');

      await _performUpload(
        onComplete: _onComplete,
        onProgress: _onProgress,
        uploadHeaders: uploadHeaders,
        client: client,
        uploadStopwatch: uploadStopwatch,
        totalBytes: totalBytes,
      );
    }

    if (_pauseUpload) {
      _log('Resume paused at offset: $_offset / $totalBytes bytes');
    } else {
      _log('Resume completed');
    }
  }

  /// Cancel the current upload and remove it from the store
  Future<bool> cancelUpload() async {
    _log('Cancelling upload');
    try {
      _log('Pausing upload before cancellation');
      await pauseUpload();

      _log('Removing upload from store: $_fingerprint');
      await store?.remove(_fingerprint);

      _log('Upload cancelled successfully');
      return true;
    } catch (e) {
      _log('Error cancelling upload: $e');
      throw Exception("Error cancelling upload");
    }
  }

  /// Actions to be performed after a successful upload
  Future<void> onCompleteUpload() async {
    _log('Upload completed, cleaning up');
    await store?.remove(_fingerprint);
    _log('Removed entry from store');
  }

  /// Set the upload data for the client
  void setUploadData(
    Uri url,
    Map<String, String>? headers,
    Map<String, String>? metadata,
  ) {
    _log('Setting upload data: url=$url');
    this.url = url;
    this.headers = headers;
    this.metadata = metadata;
    _uploadMetadata = generateMetadata();
    _log('Upload metadata: $_uploadMetadata');
  }

  /// Generate a fingerprint for the file
  @override
  String generateFingerprint() {
    _log('Generating fingerprint for file');

    // Collect reliable, platform-agnostic file identifiers
    final components = <String>[];

    // Include filename
    components.add(_file.name);
    _log('Added filename to fingerprint: ${_file.name}');

    // Include file size (safely)
    if (_file.length is Function) {
      components.add('size-dynamic');
      _log('Added dynamic size to fingerprint');
    } else {
      final size = (_file.length as int).toString();
      components.add('size-$size');
      _log('Added size to fingerprint: $size');
    }

    // Include mime type if available
    if (_file.mimeType != null && _file.mimeType!.isNotEmpty) {
      components.add('mime-${_file.mimeType!}');
      _log('Added mime type to fingerprint: ${_file.mimeType}');
    }

    // Join components with a safe delimiter
    final inputString = components.join('::');
    _log('Fingerprint input string: $inputString');

    // Hash the result for a consistent length, safe identifier
    final hash = sha256.convert(utf8.encode(inputString)).toString();
    _log('Generated hash fingerprint: $hash');

    return hash;
  }

  /// Get offset from server throwing [ProtocolException] on error
  Future<int> _getOffset() async {
    _log('Getting offset from server');
    final client = getHttpClient();

    final offsetHeaders = Map<String, String>.from(headers ?? {})
      ..addAll({
        "Tus-Resumable": tusVersion,
      });
    _log('Headers: $offsetHeaders');

    _log('Sending HEAD request to ${_uploadUrl}');
    final response =
        await client.head(_uploadUrl as Uri, headers: offsetHeaders);
    _log('Response status: ${response.statusCode}');
    _log('Response headers: ${response.headers}');

    if (!(response.statusCode >= 200 && response.statusCode < 300)) {
      _log('Error: Unexpected status code ${response.statusCode}');
      throw ProtocolException(
        "Unexpected error while resuming upload",
        response.statusCode,
      );
    }

    int? serverOffset = _parseOffset(response.headers["upload-offset"]);
    if (serverOffset == null) {
      _log('Error: Missing upload offset header');
      throw ProtocolException(
          "missing upload offset in response for resuming upload");
    }

    _log('Server offset: $serverOffset');
    return serverOffset;
  }

  /// Get data from file to upload
  Future<Uint8List> _getData() async {
    int start = _offset;
    int end = _offset + maxChunkSize;
    end = end > (_fileSize ?? 0) ? _fileSize ?? 0 : end;

    _log('Reading data chunk: start=$start, end=$end');

    // File existence check for non-web platforms before reading file
    if (!kIsWeb && _file.path.isNotEmpty) {
      try {
        final file = File(_file.path);
        if (!file.existsSync()) {
          _log('Error: File not found: ${_file.path}');
          throw Exception("Cannot find file ${_file.path.split('/').last}");
        }
      } catch (e) {
        _log('Error accessing file: $e');
        throw Exception("Cannot access file ${_file.path.split('/').last}: $e");
      }
    }

    final result = BytesBuilder();
    _log('Reading file chunk using openRead');

    // Use XFile's openRead to get a stream of the file content
    await for (final chunk in _file.openRead(start, end)) {
      result.add(chunk);
    }

    final bytesRead = min(maxChunkSize, result.length);
    _log('Read $bytesRead bytes');

    _offset = _offset + bytesRead;
    _log('New offset: $_offset');

    return result.takeBytes();
  }

  int? _parseOffset(String? offset) {
    _log('Parsing offset: $offset');
    if (offset == null || offset.isEmpty) {
      _log('Offset is null or empty');
      return null;
    }
    if (offset.contains(",")) {
      _log('Offset contains comma, taking first part');
      offset = offset.substring(0, offset.indexOf(","));
    }
    final parsedOffset = int.tryParse(offset);
    _log('Parsed offset: $parsedOffset');
    return parsedOffset;
  }

  Uri _parseUrl(String urlStr) {
    _log('Parsing URL: $urlStr');
    if (urlStr.contains(",")) {
      _log('URL contains comma, taking first part');
      urlStr = urlStr.substring(0, urlStr.indexOf(","));
    }
    Uri uploadUrl = Uri.parse(urlStr);
    _log('Initial parsed URL: $uploadUrl');

    if (uploadUrl.host.isEmpty) {
      _log('Host is empty, using host from base URL: ${url?.host}');
      uploadUrl = uploadUrl.replace(host: url?.host, port: url?.port);
    }
    if (uploadUrl.scheme.isEmpty) {
      _log('Scheme is empty, using scheme from base URL: ${url?.scheme}');
      uploadUrl = uploadUrl.replace(scheme: url?.scheme);
    }

    _log('Final parsed URL: $uploadUrl');
    return uploadUrl;
  }

  http.StreamedResponse? _response;

  int? _fileSize;

  String _fingerprint = "";

  String? _uploadMetadata;

  Uri? _uploadUrl;

  int _offset = 0;

  bool _pauseUpload = false;

  void set pausedUpload(bool value) {
    _pauseUpload = value;
  }

  /// The URI on the server for the file
  Uri? get uploadUrl => _uploadUrl;

  /// The fingerprint of the file being uploaded
  String get fingerprint => _fingerprint;

  /// The 'Upload-Metadata' header sent to server
  String get uploadMetadata => _uploadMetadata ?? "";
}
