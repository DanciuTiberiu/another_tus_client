## [3.2.7] - Added bandwidth throttling and new speed probe

- New `ThrottleOptions` sealed class with three modes:
  - `ThrottleOptions.none()` (default — no behavior change)
  - `ThrottleOptions.bandwidthFraction(0.3)` — "use ~30% of bandwidth"
  - `ThrottleOptions.bytesPerSecond(2 * 1024 * 1024)` — hard cap
- New `speedProbe` field on `TusClient` and `TusUploadManager` with a
  `DefaultSpeedProbe` implementation that hits public echo endpoints
  (`eu.httpbin.org`, `postman-echo.com`) instead of the deprecated
  speedtest.net XML config used by `speed_test_dart`.
- New `TusServerSpeedProbe` that measures throughput by performing a real
  POST/PATCH/DELETE cycle against your own TUS server. Most accurate
  option because it includes TLS, auth, and server-side processing. Runs
  1 warmup probe (silent) + 2 measured probes (best of N), with optional
  fallback to a different probe (e.g. `DefaultSpeedProbe`) if the TUS
  server is unreachable.
- New `FirstSuccessfulSpeedProbe` chain helper for composing primary +
  fallback probes.
- `setUploadTestServers()` and `uploadSpeedTest()` are now marked
  `@Deprecated` — they still work for backward compatibility but the
  underlying `speedtest.net` endpoints frequently fail with
  `XmlParserException` on EU IP ranges.

## [3.2.6] - Fixed an issue with calling cancel via the TUS Upload Manager

- The cancel method now tries to clean up no matter the state of the current upload

## [3.2.5] - Improved Manager ID

- Modified the Tus Manager Class to leverage the hash fingerprint for internal ID mapping

## [3.2.4] - Downgraded path package

- Downgraded requirement on path package

## [3.2.3] - Added debug to Upload Manager class  

- Added comprehensive debug on the upload manager

## [3.2.2] - Updated fingerprint generation and added debug  

- Fixed path error still present by using hash for fingerprint
- Added comprehensive debug on the client and all store implementations

## [3.2.1] - Fixed fingerprint generation on mobile   

- Fixed issue with file fingerprinting that caused path errors when using function references

## [3.2.0] - Web imports conditional    

- Web imports are now conditional in order to allow mobile compatibility

## [3.1.4] - Updated README

- Updated Readme

## [3.1.3] - Added Event To Stream

- Added event type to manager stream

## [3.1.2] - Added Upload Manager

- Added a simple upload manager class to manage and queue uploads
- Updated the isResumable() function on the client
- Added ability to update/remove the callbacks when calling resumeUpload()
- Added ability to prevent duplicate uploads if the same fingerprint already exists

## [3.1.1] - Removed prints

- Removed debug statements

## [3.1.0] - Added Web compatibility

- Fixed IndexedDB storage on Web
- Added custom file picker for Web
- Removed unused packages

## [3.0.0] - Added Web compatibility

- Added platformFile to XFile converter to stream files on web
- Added IndexedDB store for web
- Replaced packages incompatible on web

## [2.5.0] - Update http 1.0.0

- Update to http 1.0.0

## [2.3.0] - Added measure real time upload speed

- Added Upload Speed measure optional parameter

## [2.2.3] - Added onStart function and using TusFileStore

- Added better cancel upload method.
- Added TusClientBase abstract class.
- Changed ProtocolExceptions to include code as optional parameter.

## [2.2.2] - Change TusClient upload function

- Added onStart function with TusClient as argument.
- Added cancelUpload function.
- Deleted unused variables.
- Correct typing of functions.
- Changed ProtocolException model to separate code from message.
- Added error handling on requests.

## [2.2.1+3] - Added onStart function and using TusFileStore

- Added onStart function after initiating upload.
- Using TusFileStore for saving video locally (fixes resume-upload function).

## [2.2.1+2] - Fixed metadata and better example

- Fixed generateMetadata() function and improved example.

## [2.2.1+1] - Deleted path dependency

- Deleted path package as dependency.

## [2.2.1] - Change TusClient upload function

- Changed TusClient initialization, headers and metadata are passed now through upload function.

## [2.2.0+1] - Use http client again

- Updated dependencies.
- Now passing reference to the current TusClient in the onProgress function.

## [2.2.0] - Use http client again

- We don't use Dio anymore.

## [2.1.0] - HTTP Package updated

- Now the package uses Dio to manage HTTP Requests.
- Estimated time added.
- Chunk size issue with big files and names fixed.

## [2.0.1] - Added Persistent Store

- Users can now use TusFileStore to create persistent state of uploads.

## [1.0.3] - Updating dependencies

- Updating dependencies.
- Migrating to a native dart package.

## [1.0.2] - Fixed issue with not parsing the http port number

- Fixed issue with not parsing the http port number.
- Fixing formatting.

## [1.0.1] - Fixing custom chunk size

- Fixing handling file as chunks correctly.
- Fixing null safety warnings.
- Updating dependencies.

## [1.0.0] - Migrating to null safety

- Making null safe.
- Increasing minimum Dart SDK.
- Fixing deprecated APIs.

## [0.1.3] - Updating dependencies

- Updating dependencies.
- Removing deadcode.

## [0.1.2] - Many improvements

- Fixing server returns partial url & double header.
- Fixing immediate pause even when uploading with large chunks by timing out the future.
- Removing unused exceptions (deadcode).
- Updating dependencies.

## [0.1.1] - Better file persistence documentation

- Have better documentation on using tus_client_file_store.

## [0.1.0] - Web support

- This is update breaks backwards compatibility.
- Adding cross_file Flutter plugin to manage reading files across platforms.
- Refactoring example to show use with XFile on Android/iOS vs web.

## [0.0.4] - Feature request

- Changing example by adding copying file to be uploaded to application temp directory before uploading.

## [0.0.3] - Bug fix

- Fixing missing Tus-Resumable headers in all requests.

## [0.0.2] - Bug fix

- Fixing failure when offset for server is missing or null.

## [0.0.1] - Initial release

- Support for TUS 1.0.0 protocol.
- Uploading in chunks.
- Basic protocol support.
- **TODO**: Add support for multiple file upload.
- **TODO**: Add support for partial file uploads.
