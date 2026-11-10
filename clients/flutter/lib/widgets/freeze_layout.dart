import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// While [frozen], the child keeps being laid out with the constraints it had when it was last not frozen, so a hidden page does not lay itself out again every time the window
/// is resized (an `Offstage` child still does). When it is shown again it gets the real constraints and lays out once. The child's own state and scroll positions are untouched.
class FreezeLayout extends SingleChildRenderObjectWidget {
  const FreezeLayout({super.key, required this.frozen, super.child});

  final bool frozen;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderFreezeLayout(frozen);

  @override
  void updateRenderObject(BuildContext context, _RenderFreezeLayout renderObject) => renderObject.frozen = frozen;
}

class _RenderFreezeLayout extends RenderProxyBox {
  _RenderFreezeLayout(this._frozen);

  bool _frozen;
  BoxConstraints? _last;

  set frozen(bool v) {
    if (v == _frozen) return;
    _frozen = v;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    final c = (_frozen && _last != null) ? _last! : constraints;
    if (!_frozen) _last = constraints;
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(c, parentUsesSize: true);
    size = constraints.constrain(child.size);
  }
}
