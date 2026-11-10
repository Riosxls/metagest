using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Ebt.Core.Data.Migrations
{
    /// <inheritdoc />
    public partial class OfMaterialsAndLegacyHistory : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<string>(
                name: "raw_material",
                table: "production_orders",
                type: "text",
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "primary_tube",
                table: "process_templates",
                type: "text",
                nullable: true);

            migrationBuilder.AddColumn<string>(
                name: "raw_material",
                table: "process_templates",
                type: "text",
                nullable: true);

            migrationBuilder.AlterColumn<string>(
                name: "material",
                table: "order_materials",
                type: "character varying(200)",
                maxLength: 200,
                nullable: true,
                oldClrType: typeof(string),
                oldType: "character varying(200)",
                oldMaxLength: 200);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropColumn(
                name: "raw_material",
                table: "production_orders");

            migrationBuilder.DropColumn(
                name: "primary_tube",
                table: "process_templates");

            migrationBuilder.DropColumn(
                name: "raw_material",
                table: "process_templates");

            migrationBuilder.AlterColumn<string>(
                name: "material",
                table: "order_materials",
                type: "character varying(200)",
                maxLength: 200,
                nullable: false,
                defaultValue: "",
                oldClrType: typeof(string),
                oldType: "character varying(200)",
                oldMaxLength: 200,
                oldNullable: true);
        }
    }
}
