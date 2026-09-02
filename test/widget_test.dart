import 'package:flutter_test/flutter_test.dart';

import 'package:apng_viewer/main.dart';

void main() {
  testWidgets('APNG Viewer home smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const ApngViewerApp());
    await tester.pumpAndSettle();

    // 验证主页元素存在
    expect(find.text('APNG 阅览器'), findsOneWidget);
    expect(find.text('APNG 动画图片阅览器'), findsOneWidget);
    expect(find.text('阅览图片'), findsOneWidget);
    expect(find.text('图片互转'), findsOneWidget);
  });
}
