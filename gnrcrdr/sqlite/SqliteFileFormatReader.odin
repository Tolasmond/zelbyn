package sqlite

import sql "../../sqlite3"
import "../data"
import "../manip"
import "../metadata"
import "core:log"
import "core:mem"
import "core:strings"

readFileFormat :: proc(dbFilePath: string, formatId: int, fileFormat: ^metadata.FileFormat) {
	log.debugf("Opening database and reading format ID %v", formatId)
	db, err := db_init(strings.clone_to_cstring(dbFilePath))
	db_check(db, err)
	defer sql.close(db)

	result := readDataType(db, &fileFormat.metadataProvider.dataTypeMap)

	result = readLength(db, &fileFormat.metadataProvider.setLengthMap)

	result = readMarkerOffset(db, &fileFormat.metadataProvider.markerOffsetMap)

	result = readSetHelper(db, &fileFormat.metadataProvider.setHelperMap)

	packedRecords := make([dynamic]^data.PackedRecord)

	result = readPacked(db, &packedRecords)

	fileFormat.metadataProvider.packedRecords = packedRecords

	result = readField(
		db,
		packedRecords[:],
		&fileFormat.metadataProvider.dataTypeMap,
		&fileFormat.metadataProvider.fieldMetadataMap,
	)

	result = readFormat(db, &fileFormat.metadataProvider.formatRecord)

	result = readParent(db, &fileFormat.metadataProvider.parentMap)

	fileFormat.rootMetadataTreeNode.fieldMetadata =
		fileFormat.metadataProvider.fieldMetadataMap[fileFormat.metadataProvider.formatRecord.rootField]

	log.debug("reading children")

	readChildren(&fileFormat.rootMetadataTreeNode, &fileFormat.metadataProvider)

  log.debug("closing database connection")
}

@(private = "file")
readChildren :: proc(
	parentTreeNode: ^metadata.FieldMetadataTreeNode, fieldMetadataProvider: ^metadata.FieldMetadataProvider) {

	parentMap := &fieldMetadataProvider.parentMap
	fieldMetadataMap := &fieldMetadataProvider.fieldMetadataMap

	keyExists := parentTreeNode.fieldMetadata.id in parentMap

	for childRecord in parentMap[parentTreeNode.fieldMetadata.id] {

		childTreeNode := new(metadata.FieldMetadataTreeNode)

		childTreeNode.fieldMetadata = fieldMetadataMap[childRecord.childId]

		childTreeNode.parent = parentTreeNode

		append(&parentTreeNode.children, childTreeNode)

		if (data.DataType(childTreeNode.fieldMetadata.dataType.type) == .Set) {
      readChildren(childTreeNode, fieldMetadataProvider)
		}
	}
}
