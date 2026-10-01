import 'package:flutter/material.dart';

/// 左滑露出操作按钮的行容器（不删除，需用户再点按钮才执行）。
///
/// 为什么不用 `Dismissible`：它滑到底就**直接删除**，缺少"露出按钮 → 点击确认"
/// 这一步，容易误删（用户反馈）。
/// 为什么不用 `flutter_slidable`：避免为单一交互引入新依赖。
///
/// 交互：
/// - 左滑：行内容左移，露出右侧操作按钮（红色「删除」）；
/// - 松手：位移超过一半或快速甩动则**吸附到展开位**，否则回弹关闭；
/// - 点击操作按钮：执行 [onAction]（此时才真正删除）；
/// - 展开状态下点击行内容区域：先关闭，不触发删除。
class SwipeRevealRow extends StatefulWidget {
  const SwipeRevealRow({
    super.key,
    required this.child,
    required this.onAction,
    this.actionWidth = 96,
    this.actionLabel = '删除',
    this.actionIcon = Icons.delete_outline,
    this.actionColor = const Color(0xFFE5484D),
  });

  final Widget child;
  final VoidCallback onAction;
  final double actionWidth;
  final String actionLabel;
  final IconData actionIcon;
  final Color actionColor;

  @override
  State<SwipeRevealRow> createState() => _SwipeRevealRowState();
}

class _SwipeRevealRowState extends State<SwipeRevealRow>
    with SingleTickerProviderStateMixin {
  /// 0 = 关闭，1 = 完全展开。
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );

  bool get _isOpen => _controller.value > 0.01;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final delta = details.primaryDelta ?? 0;
    if (delta == 0) return;
    // 左滑（负值）增大展开度；右滑减小。夹在 0..1。
    final next = (_controller.value - delta / widget.actionWidth).clamp(0.0, 1.0);
    _controller.value = next;
  }

  void _onDragEnd(DragEndDetails details) {
    final velocity = details.velocity.pixelsPerSecond.dx;
    // 快速左甩或已过半 → 展开；否则回弹。
    if (velocity < -300 || _controller.value > 0.5) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final shift = _controller.value * widget.actionWidth;
        return Stack(
          children: [
            // 底层：操作按钮（行左移后露出来）。
            Positioned.fill(
              child: Align(
                alignment: Alignment.centerRight,
                child: SizedBox(
                  width: widget.actionWidth,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Material(
                      color: widget.actionColor,
                      borderRadius: const BorderRadius.horizontal(
                        right: Radius.circular(12),
                        left: Radius.circular(12),
                      ),
                      child: InkWell(
                        borderRadius: const BorderRadius.horizontal(
                          right: Radius.circular(12),
                          left: Radius.circular(12),
                        ),
                        onTap: () {
                          _controller.reverse();
                          widget.onAction();
                        },
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(widget.actionIcon,
                                color: Colors.white, size: 20),
                            const SizedBox(height: 2),
                            Text(
                              widget.actionLabel,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // 上层：行内容（跟随手指左移）。
            Transform.translate(
              offset: Offset(-shift, 0),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: _onDragUpdate,
                onHorizontalDragEnd: _onDragEnd,
                child: child,
              ),
            ),
            // 展开时：点击行内容区域先关闭（避免误触到下层按钮/触发行内点击）。
            if (_isOpen)
              Positioned(
                left: 0,
                right: widget.actionWidth,
                top: 0,
                bottom: 0,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () => _controller.reverse(),
                ),
              ),
          ],
        );
      },
      child: widget.child,
    );
  }
}
