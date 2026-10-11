import '../../data/auth_service.dart';
import '../../data/database.dart';
import '../../data/tables.dart';

/// Void, return and discount all need the owner or a clinician. Those two
/// approve their own actions; a cashier has one of them type their PIN.
bool canSelfApprove(User me) =>
    me.role == Role.owner || me.role == Role.clinician;

/// Works out who approved. Returns that person, or throws [StaffRuleException]
/// with a message for the screen. A cashier's own PIN is not accepted.
Future<User> resolveApprover(AuthService auth, User me, String pin) async {
  if (canSelfApprove(me)) return me;
  if (pin.isEmpty) {
    throw StaffRuleException(
      'Ask the owner or a clinician to enter their PIN.',
    );
  }
  final approver = await auth.verifyApprover(pin);
  if (approver == null) {
    throw StaffRuleException(
      'That PIN is not right. It must be the owner’s or a clinician’s.',
    );
  }
  return approver;
}
