import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

void main() async {
  // Đảm bảo các dịch vụ hệ thống của Flutter được khởi tạo trước
  WidgetsFlutterBinding.ensureInitialized();

  // Lấy danh sách camera có sẵn trên thiết bị
  final cameras = await availableCameras();
  runApp(MyApp(cameras: cameras));
}

class MyApp extends StatelessWidget {
  final List<CameraDescription> cameras;
  const MyApp({super.key, required this.cameras});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI Fitness Counter',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.black,
        primaryColor: Colors.green,
      ),
      debugShowCheckedModeBanner: false,
      home: FitnessCounterScreen(cameras: cameras),
    );
  }
}

// Định nghĩa 3 bài tập bằng Enum
enum ExerciseType { pushUp, squat, sitUp }

class FitnessCounterScreen extends StatefulWidget {
  final List<CameraDescription> cameras;
  const FitnessCounterScreen({super.key, required this.cameras});

  @override
  State<FitnessCounterScreen> createState() => _FitnessCounterScreenState();
}

class _FitnessCounterScreenState extends State<FitnessCounterScreen> {
  late CameraController _cameraController;
  late PoseDetector _poseDetector;
  bool _isProcessing = false;
  bool _isPoseDetected = false;

  // Quản lý trạng thái bài tập
  ExerciseType _currentExercise = ExerciseType.pushUp;
  int _counter = 0;
  String _motionState =
      "UP"; // UP: Đang ở vị trí cao/thẳng, DOWN: Đang ở vị trí hạ thấp/gập

  @override
  void initState() {
    super.initState();

    // Khởi tạo bộ phát hiện dáng người (Pose Detector) ở chế độ Stream hình ảnh liên tục
    _poseDetector = PoseDetector(
      options: PoseDetectorOptions(
        model: PoseDetectionModel.base,
        mode: PoseDetectionMode.stream,
      ),
    );

    // Khởi tạo camera đầu tiên trong danh sách (thường là camera sau)
    // Bạn có thể đổi sang widget.cameras[1] nếu muốn mặc định dùng camera trước (selfie)
    _cameraController = CameraController(
      widget.cameras[0],
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup.nv21
          : ImageFormatGroup.bgra8888,
    );

    _cameraController.initialize().then((_) {
      if (!mounted) return;

      // Bắt đầu luồng stream hình ảnh trực tiếp từ camera về cho AI
      _cameraController.startImageStream((cameraImage) {
        if (!_isProcessing) {
          _isProcessing = true;
          _processImage(cameraImage);
        }
      });
      setState(() {});
    });
  }

  // Hàm toán học tính góc giữa 3 điểm A, B, C với B là đỉnh góc (ví dụ: Vai - Khuỷu tay - Cổ tay)
  double _calculateAngle(PoseLandmark a, PoseLandmark b, PoseLandmark c) {
    double radians =
        math.atan2(c.y - b.y, c.x - b.x) - math.atan2(a.y - b.y, a.x - b.x);
    double angle = radians.abs() * 180.0 / math.pi;
    if (angle > 180.0) {
      angle = 360.0 - angle;
    }
    return angle;
  }

  // Hàm chuyển đổi dữ liệu hình ảnh của Camera thành định dạng ML Kit có thể đọc được
  void _processImage(CameraImage image) async {
    final format = InputImageFormatValue.fromRawValue(
      image.format.raw as int? ?? 0,
    );
    if (format == null ||
        (Platform.isAndroid && format != InputImageFormat.nv21) ||
        (Platform.isIOS && format != InputImageFormat.bgra8888)) {
      _isProcessing = false;
      return;
    }

    if (image.planes.length != 1) {
      _isProcessing = false;
      return;
    }

    final plane = image.planes.first;
    final rotation =
        InputImageRotationValue.fromRawValue(
          _cameraController.description.sensorOrientation,
        ) ??
        InputImageRotation.rotation0deg;

    final inputImage = InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: plane.bytesPerRow,
      ),
    );

    // Gọi AI phân tích hình ảnh để tìm các khớp xương
    final poses = await _poseDetector.processImage(inputImage);
    _isPoseDetected = poses.isNotEmpty;

    if (poses.isNotEmpty) {
      final pose = poses.first;

      // Chạy thuật toán đếm số lần dựa vào bài tập đang chọn
      switch (_currentExercise) {
        // 1. LOGIC HÍT ĐẤT (Theo dõi góc khuỷu tay bên phải)
        case ExerciseType.pushUp:
          final shoulder = pose.landmarks[PoseLandmarkType.rightShoulder];
          final elbow = pose.landmarks[PoseLandmarkType.rightElbow];
          final wrist = pose.landmarks[PoseLandmarkType.rightWrist];

          if (shoulder != null && elbow != null && wrist != null) {
            double angle = _calculateAngle(shoulder, elbow, wrist);
            if (angle < 90 && _motionState == "UP") {
              _motionState = "DOWN";
            } else if (angle > 160 && _motionState == "DOWN") {
              _motionState = "UP";
              _counter++;
            }
          }
          break;

        // 2. LOGIC SQUAT (Theo dõi góc đầu gối bên phải)
        case ExerciseType.squat:
          final hip = pose.landmarks[PoseLandmarkType.rightHip];
          final knee = pose.landmarks[PoseLandmarkType.rightKnee];
          final ankle = pose.landmarks[PoseLandmarkType.rightAnkle];

          if (hip != null && knee != null && ankle != null) {
            double angle = _calculateAngle(hip, knee, ankle);
            if (angle < 100 && _motionState == "UP") {
              _motionState = "DOWN"; // Đã ngồi xuống sâu
            } else if (angle > 160 && _motionState == "DOWN") {
              _motionState = "UP"; // Đã đứng thẳng dậy
              _counter++;
            }
          }
          break;

        // 3. LOGIC GẬP BỤNG (Theo dõi góc hông bên phải)
        case ExerciseType.sitUp:
          final shoulder = pose.landmarks[PoseLandmarkType.rightShoulder];
          final hip = pose.landmarks[PoseLandmarkType.rightHip];
          final knee = pose.landmarks[PoseLandmarkType.rightKnee];

          if (shoulder != null && hip != null && knee != null) {
            double angle = _calculateAngle(shoulder, hip, knee);
            if (angle > 135 && _motionState == "UP") {
              _motionState = "DOWN"; // Đang nằm ngửa trên sàn
            } else if (angle < 130 && _motionState == "DOWN") {
              _motionState = "UP"; // Đã gập người lên cao
              _counter++;
            }
          }
          break;
      }

      if (mounted) setState(() {});
    }

    // Giải phóng cờ để sẵn sàng xử lý khung hình tiếp theo từ camera
    _isProcessing = false;
  }

  // Thay đổi bài tập hiện tại và reset bộ đếm về 0
  void _changeExercise(ExerciseType type) {
    setState(() {
      _currentExercise = type;
      _counter = 0;
      _motionState = "UP";
    });
  }

  @override
  void dispose() {
    _cameraController.dispose();
    unawaited(_poseDetector.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Nếu camera chưa khởi tạo xong, hiển thị vòng tròn tải dữ liệu
    if (!_cameraController.value.isInitialized) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator(color: Colors.green)),
      );
    }

    return Scaffold(
      body: Stack(
        children: [
          // 1. Lớp nền hiển thị Camera trực tiếp
          Positioned.fill(child: CameraPreview(_cameraController)),

          // 2. Viền trạng thái nhận diện tư thế trên camera
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: _isPoseDetected
                        ? Colors.greenAccent
                        : Colors.redAccent,
                    width: _isPoseDetected ? 3 : 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color:
                          (_isPoseDetected
                                  ? Colors.greenAccent
                                  : Colors.redAccent)
                              .withValues(alpha: 0.18),
                      blurRadius: 16,
                      spreadRadius: 2,
                    ),
                  ],
                ),
              ),
            ),
          ),

          Positioned(
            top: 18,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: _isPoseDetected
                      ? Colors.green.withValues(alpha: 0.18)
                      : Colors.red.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: _isPoseDetected
                        ? Colors.greenAccent
                        : Colors.redAccent,
                    width: 1,
                  ),
                ),
                child: Text(
                  _isPoseDetected
                      ? 'Đang nhận diện tư thế'
                      : 'Chưa nhận diện tư thế',
                  style: TextStyle(
                    color: _isPoseDetected
                        ? Colors.greenAccent
                        : Colors.redAccent,
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
            ),
          ),

          // 3. Bảng điều khiển hiển thị thông số (Số lần tập, trạng thái)
          Positioned(
            top: 60,
            left: 20,
            right: 20,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.8),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white24, width: 1),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _currentExercise == ExerciseType.pushUp
                            ? "HÍT ĐẤT (PUSH-UP)"
                            : _currentExercise == ExerciseType.squat
                            ? "SQUAT (GHÁNH ĐÙI)"
                            : "GẬP BỤNG (SIT-UP)",
                        style: const TextStyle(
                          fontSize: 16,
                          color: Colors.greenAccent,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.2,
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: _motionState == "UP"
                              ? Colors.orange.withValues(alpha: 0.2)
                              : Colors.blue.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: _motionState == "UP"
                                ? Colors.orange
                                : Colors.blue,
                          ),
                        ),
                        child: Text(
                          _motionState,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: _motionState == "UP"
                                ? Colors.orange
                                : Colors.blue,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const Divider(color: Colors.white12, height: 20),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        '$_counter',
                        style: const TextStyle(
                          fontSize: 56,
                          fontWeight: FontWeight.w900,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'lần',
                        style: TextStyle(fontSize: 18, color: Colors.grey),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          // 3. Thanh điều hướng đổi bài tập nằm ở dưới đáy màn hình
          Positioned(
            bottom: 40,
            left: 16,
            right: 16,
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(30),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: _buildExerciseTab("Hít đất", ExerciseType.pushUp),
                  ),
                  Expanded(
                    child: _buildExerciseTab("Squat", ExerciseType.squat),
                  ),
                  Expanded(
                    child: _buildExerciseTab("Gập bụng", ExerciseType.sitUp),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Widget tạo nút Tab chuyển đổi bài tập đẹp mắt
  Widget _buildExerciseTab(String title, ExerciseType type) {
    bool isSelected = _currentExercise == type;
    return GestureDetector(
      onTap: () => _changeExercise(type),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: isSelected ? Colors.green : Colors.transparent,
          borderRadius: BorderRadius.circular(25),
        ),
        child: Center(
          child: Text(
            title,
            style: TextStyle(
              color: isSelected ? Colors.black : Colors.white70,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              fontSize: 14,
            ),
          ),
        ),
      ),
    );
  }
}
