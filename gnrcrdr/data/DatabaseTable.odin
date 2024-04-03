package data


DataTypeRecord :: struct {
	id: int,
	type: int,
	minValue: Maybe(string),
	maxValue: Maybe(string),
	defaultValue: Maybe(string),
	units: Maybe(string),
	minArrayLength: Maybe(int),
	maxArrayLength: Maybe(int),
	isGrowAsNeeded: Maybe(int),
	pattern: Maybe(string),
	comparisonTolerance: Maybe(f64),
	minBufferLength: Maybe(int),
	maxBufferLength: Maybe(int)
}

FieldRecord :: struct {
	id: int,
	name: string,
	dataTypeId: int
}

SetHelperRecord :: struct {
	formatId: int,
	fieldId: int,
	lengthId: Maybe(int),
	markerId: Maybe(int)
}

LengthRecord :: struct {
	id: int,
	dataTypeId: int,
	flagAbsouteOffsetFromBeginning: Maybe(int),
	flagRelativeOffsetFromField: Maybe(int),
	valueAbsoluteOffsetFromBeginning: Maybe(int),
	valueRelativeOffsetFromField: Maybe(int),
	continuator: Maybe(int),
	terminator: Maybe(int),
	flagMask: Maybe(int),
	flagShift: Maybe(int),
	valueMask: Maybe(int),
	valueShift: Maybe(int),
	flagExpression: Maybe(string),
	valueExpression: Maybe(string)
}

MarkerOffsetRecord :: struct {
	markerId: int,
	byteOffset: int,
	dataTypeId: int,
	marker: int
}

PackedRecord :: struct {
	id: int,
	fieldId: int,
	lowBit: int,
	highBit: int
}

FormatRecord :: struct {
	id: int,
	name: string,
	rootField: int
}

ParentRecord :: struct {
	formatId: int,
	parentId: int,
	childId: int,
	childIndex: int
}

sortParentRecordsByChildIndex :: proc(i, j: ^ParentRecord) -> bool {
	return i.childIndex < j.childIndex
}
