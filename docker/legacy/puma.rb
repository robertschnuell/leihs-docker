workers(2)
threads(1, 5)
bind("tcp://0.0.0.0:#{ENV.fetch('LEIHS_LEGACY_PORT', '3210')}")
environment("production")
