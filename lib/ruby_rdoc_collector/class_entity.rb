module RubyRdocCollector
  MethodEntry = Data.define(:name, :call_seq, :description)
  ClassEntity = Data.define(:name, :description, :methods, :constants, :superclass)
end
