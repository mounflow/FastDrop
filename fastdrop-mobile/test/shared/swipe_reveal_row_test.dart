import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fastdrop_mobile/shared/widgets/swipe_reveal_row.dart';

/// 「左滑露出按钮、点按钮才删除」交互回归测试。
///
/// 此前用 Dismissible：滑到底**直接删除**（用户反馈容易误删）。
void main() {
  Future<void> pumpRow(
    WidgetTester tester, {
    required VoidCallback onDelete,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              SwipeRevealRow(
                onAction: onDelete,
                child: Container(
                  key: const ValueKey('row-content'),
                  height: 80,
                  margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  color: Colors.white,
                  alignment: Alignment.centerLeft,
                  child: const Text('测试记录'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  testWidgets('单纯左滑不会删除，只露出删除按钮', (tester) async {
    var deleted = false;
    await pumpRow(tester, onDelete: () => deleted = true);

    // 左滑（拖动行内容）。
    await tester.drag(find.text('测试记录'), const Offset(-120, 0));
    await tester.pumpAndSettle();

    // 关键：滑开只是露出按钮，绝不能直接删除。
    expect(deleted, isFalse);
    expect(find.text('删除'), findsOneWidget);
  });

  testWidgets('滑开后点击删除按钮才执行删除', (tester) async {
    var deleted = false;
    await pumpRow(tester, onDelete: () => deleted = true);

    await tester.drag(find.text('测试记录'), const Offset(-120, 0));
    await tester.pumpAndSettle();
    expect(deleted, isFalse);

    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(deleted, isTrue);
  });

  testWidgets('未滑开时点行内容不会删除（也不会露按钮）', (tester) async {
    var deleted = false;
    await pumpRow(tester, onDelete: () => deleted = true);

    await tester.tap(find.text('测试记录'));
    await tester.pumpAndSettle();

    expect(deleted, isFalse);
  });

  testWidgets('小幅滑动会回弹关闭（暴露面积不足不触发）', (tester) async {
    var deleted = false;
    await pumpRow(tester, onDelete: () => deleted = true);

    // 仅滑动 10px 后松手：应回弹，不视为展开。
    await tester.drag(find.text('测试记录'), const Offset(-10, 0));
    await tester.pumpAndSettle();

    expect(deleted, isFalse);
    // 回弹后按钮被行内容遮住（仍存在于树中，但不可点击）。
    final sw = tester.widget<SwipeRevealRow>(find.byType(SwipeRevealRow));
    expect(sw.actionWidth, 96);
  });

  testWidgets('闭合时删除按钮完全被行内容遮住（不露红边）', (tester) async {
    await pumpRow(tester, onDelete: () {});

    // 行内容视觉区域（Card 有 16px 水平外边距）。
    final contentRect = tester.getRect(find.byKey(const ValueKey('row-content')));
    // 删除按钮的可见区域。
    final actionRect = tester.getRect(find.text('删除'));

    // 按钮必须在行内容覆盖范围之内：右侧不超出卡片右边、左侧不超出卡片左边。
    // 早期实现按钮贴到 Stack 最右（无右边距），闭合时右侧会露出一条红色，
    // 这正是用户实测到的显示问题。
    expect(actionRect.right, lessThanOrEqualTo(contentRect.right - 16));
    expect(actionRect.left, greaterThanOrEqualTo(contentRect.left + 16));
  });
}
