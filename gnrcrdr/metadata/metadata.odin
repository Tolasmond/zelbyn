package metadata

import dat "../data"

Field_Metadata :: struct {
	id: int,
	name: string,
	data_type: ^dat.Data_Type_Record,
	packed_fields: []^dat.Packed_Record,
}
