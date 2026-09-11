sealed class AutoGroupFailure {
  const AutoGroupFailure();

  String get message;
}

class AutoGroupNoMembers extends AutoGroupFailure {
  const AutoGroupNoMembers();

  @override
  String get message => 'no subscriptions are included in the auto group';
}

class AutoGroupNoServers extends AutoGroupFailure {
  const AutoGroupNoServers(this.warnings);

  final List<String> warnings;

  @override
  String get message => 'included subscriptions contain no servers: ${warnings.join('; ')}';
}

class AutoGroupInvalidConfig extends AutoGroupFailure {
  const AutoGroupInvalidConfig(this.detail);

  final String detail;

  @override
  String get message => 'merged config rejected by core: $detail';
}

class AutoGroupUnexpected extends AutoGroupFailure {
  const AutoGroupUnexpected(this.error, [this.stackTrace]);

  final Object error;
  final StackTrace? stackTrace;

  @override
  String get message => 'unexpected error while building auto group: $error';
}
