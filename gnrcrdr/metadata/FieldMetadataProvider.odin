package metadata

FieldMetadataProvider :: struct {
  dataTypeMap: map[i32]^DataTypeRecord,
  fieldMetadataMap: map[i32]^FieldMetadata,
  setHelperMap: map[i32]^SetHelperRecord,
  setLengthMap: map[i32]^LengthRecord,
  markerOffsetMap: map[i32]^MarkerOffsetRecord,
  packedRecords: [dynamic]^PackedRecord,
  formatRecord: FormatRecord,
  //parentRecords: [dynamic]^ParentRecord
  parentMap: map[i32][dynamic]^ParentRecord
}

DataTypeRecord :: struct {
	id: i32,
	type: i32,
	minValue: Maybe(string),
	maxValue: Maybe(string),
	defaultValue: Maybe(string),
	units: Maybe(string),
	minArrayLength: Maybe(i32),
	maxArrayLength: Maybe(i32),
	isGrowAsNeeded: Maybe(i32),
	pattern: Maybe(string),
	comparisonTolerance: Maybe(f64),
	minBufferLength: Maybe(i32),
	maxBufferLength: Maybe(i32)
}

FieldRecord :: struct {
	id: i32,
	name: string,
	dataTypeId: i32
}

SetHelperRecord :: struct {
	formatId: i32,
	fieldId: i32,
	lengthId: Maybe(i32),
	markerId: Maybe(i32)
}

LengthRecord :: struct {
	id: i32,
	dataTypeId: i32,
	flagAbsouteOffsetFromBeginning: Maybe(i32),
	flagRelativeOffsetFromField: Maybe(i32),
	valueAbsoluteOffsetFromBeginning: Maybe(i32),
	valueRelativeOffsetFromField: Maybe(i32),
	continuator: Maybe(i32),
	terminator: Maybe(i32),
	flagMask: Maybe(i32),
	flagShift: Maybe(i32),
	valueMask: Maybe(i32),
	valueShift: Maybe(i32),
	flagExpression: Maybe(string),
	valueExpression: Maybe(string)
}

MarkerOffsetRecord :: struct {
	markerId: i32,
	byteOffset: i32,
	dataTypeId: i32,
	marker: i32
}

PackedRecord :: struct {
	id: i32,
	fieldId: i32,
	lowBit: i32,
	highBit: i32
}

FormatRecord :: struct {
	id: i32,
	name: string,
	rootField: i32
}

ParentRecord :: struct {
	formatId: i32,
	parentId: i32,
	childId: i32,
	childIndex: i32
}

sortParentRecordsByChildIndex :: proc(i, j: ^ParentRecord) -> bool {
	return i.childIndex < j.childIndex
}