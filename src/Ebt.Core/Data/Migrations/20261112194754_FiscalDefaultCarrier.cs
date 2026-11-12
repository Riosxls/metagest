using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Ebt.Core.Data.Migrations
{
    /// <inheritdoc />
    public partial class FiscalDefaultCarrier : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<string>(
                name: "default_carrier",
                table: "fiscal_settings",
                type: "text",
                nullable: true);

            migrationBuilder.UpdateData(
                table: "fiscal_settings",
                keyColumn: "id",
                keyValue: 1,
                column: "default_carrier",
                value: "BTS");

            migrationBuilder.UpdateData(
                table: "fiscal_settings",
                keyColumn: "id",
                keyValue: 2,
                column: "default_carrier",
                value: "BST");

            // The old NFs carry this sentence on every sale; it was empty in the register.
            migrationBuilder.Sql("UPDATE cfops SET legal_text = 'MERCADORIA OBJETO DE COMERCIALIZACAO E/OU INDUSTRIALIZACAO PELO DESTINATARIO.' WHERE code IN ('5101', '6101') AND (legal_text IS NULL OR legal_text = '')");
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropColumn(
                name: "default_carrier",
                table: "fiscal_settings");
        }
    }
}
