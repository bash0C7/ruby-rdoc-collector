Gem::Specification.new do |spec|
  spec.name          = 'ruby_rdoc_collector'
  spec.version       = '0.1.0'
  spec.summary       = 'RDoc HTML collector for ruby knowledge DB'
  spec.authors       = ['bash0C7']
  spec.files         = Dir['lib/**/*.rb']
  spec.require_paths = ['lib']
  spec.required_ruby_version = '>= 3.2.0'
  spec.add_dependency 'oga'
end
