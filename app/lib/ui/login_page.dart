import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  String? _error;
  bool _busy = false;

  Future<void> _signIn() async {
    final t = ref.read(l10nProvider);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(firebaseAuthProvider).signInWithEmailAndPassword(
          email: _email.text.trim(), password: _password.text);
      // 只在登录成功后收口 autofill，系统才会弹「是否保存密码」；失败时调用
      // 会把打错的密码存进钥匙串，下次自动填充反而登不进去。
      TextInput.finishAutofillContext();
      // 登录页可能已在未认证状态下建立过 settings 监听（会被规则拒掉并终止），
      // 认证成功后重建，语言偏好才能正常流动。
      ref.invalidate(settingsProvider);
    } on FirebaseAuthException catch (e) {
      if (mounted) setState(() => _error = e.message ?? t.signInFailed);
    } catch (e) {
      if (mounted) setState(() => _error = t.signInError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(l10nProvider);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(t.appTitle,
                    textAlign: TextAlign.center, style: const TextStyle(fontSize: 24)),
                const SizedBox(height: 24),
                // AutofillGroup 把两个框声明成一组凭据，系统密码管理器
                // （iOS 钥匙串 / Chrome 密码管理器）才认得出这是登录表单。
                AutofillGroup(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                          key: const Key('email'),
                          controller: _email,
                          decoration: InputDecoration(labelText: t.email),
                          keyboardType: TextInputType.emailAddress,
                          autofillHints: const [AutofillHints.username],
                          textInputAction: TextInputAction.next),
                      const SizedBox(height: 12),
                      TextField(
                          key: const Key('password'),
                          controller: _password,
                          decoration: InputDecoration(labelText: t.password),
                          obscureText: true,
                          autofillHints: const [AutofillHints.password],
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => _busy ? null : _signIn()),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                if (_error != null)
                  Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(_error!, style: const TextStyle(color: Colors.red))),
                FilledButton(
                  key: const Key('signInButton'),
                  onPressed: _busy ? null : _signIn,
                  child: _busy
                      ? const SizedBox(
                          height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(t.signIn),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
