using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace Ebt.Core.Data.Migrations
{
            // Documents and inutilizations that exist today were all issued by the single issuer row (id 1), which becomes EBT; the new columns default to it.
    /// <inheritdoc />
    public partial class FiscalIssuers : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            // Documents and inutilizations that exist today were all issued by the single issuer row (id 1), which becomes EBT; the new columns default to it.
            migrationBuilder.DropIndex(
                name: "ix_fiscal_inutilizations_series_from_number_to_number",
                table: "fiscal_inutilizations");

            migrationBuilder.DropIndex(
                name: "ix_fiscal_documents_series_number",
                table: "fiscal_documents");

            migrationBuilder.AddColumn<string>(
                name: "company",
                table: "fiscal_settings",
                type: "character varying(3)",
                maxLength: 3,
                nullable: false,
                defaultValue: "");

            migrationBuilder.AddColumn<int>(
                name: "issuer_id",
                table: "fiscal_inutilizations",
                type: "integer",
                nullable: false,
                defaultValue: 1);

            migrationBuilder.AddColumn<int>(
                name: "issuer_id",
                table: "fiscal_documents",
                type: "integer",
                nullable: false,
                defaultValue: 1);

            migrationBuilder.UpdateData(
                table: "fiscal_settings",
                keyColumn: "id",
                keyValue: 1,
                column: "company",
                value: "EBT");

            migrationBuilder.InsertData(
                table: "fiscal_settings",
                columns: new[] { "id", "cancel_window_hours", "city", "city_ibge_code", "cnpj", "company", "company_name", "complement", "district", "enabled", "environment", "next_number", "number", "phone", "series", "state_registration", "street", "tax_regime", "trade_name", "uf", "zip_code" },
                values: new object[] { 2, 24, null, null, null, "BST", null, null, null, false, 2, 897, null, null, 1, null, null, 3, null, "SP", null });

            migrationBuilder.CreateIndex(
                name: "ix_fiscal_settings_company",
                table: "fiscal_settings",
                column: "company",
                unique: true);

            migrationBuilder.CreateIndex(
                name: "ix_fiscal_inutilizations_issuer_id_series_from_number_to_number",
                table: "fiscal_inutilizations",
                columns: new[] { "issuer_id", "series", "from_number", "to_number" });

            migrationBuilder.CreateIndex(
                name: "ix_fiscal_documents_issuer_id_series_number",
                table: "fiscal_documents",
                columns: new[] { "issuer_id", "series", "number" },
                unique: true);

            migrationBuilder.AddForeignKey(
                name: "fk_fiscal_documents_fiscal_settings_issuer_id",
                table: "fiscal_documents",
                column: "issuer_id",
                principalTable: "fiscal_settings",
                principalColumn: "id",
                onDelete: ReferentialAction.Restrict);

            migrationBuilder.AddForeignKey(
                name: "fk_fiscal_inutilizations_fiscal_settings_issuer_id",
                table: "fiscal_inutilizations",
                column: "issuer_id",
                principalTable: "fiscal_settings",
                principalColumn: "id",
                onDelete: ReferentialAction.Restrict);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropForeignKey(
                name: "fk_fiscal_documents_fiscal_settings_issuer_id",
                table: "fiscal_documents");

            migrationBuilder.DropForeignKey(
                name: "fk_fiscal_inutilizations_fiscal_settings_issuer_id",
                table: "fiscal_inutilizations");

            migrationBuilder.DropIndex(
                name: "ix_fiscal_settings_company",
                table: "fiscal_settings");

            migrationBuilder.DropIndex(
                name: "ix_fiscal_inutilizations_issuer_id_series_from_number_to_number",
                table: "fiscal_inutilizations");

            migrationBuilder.DropIndex(
                name: "ix_fiscal_documents_issuer_id_series_number",
                table: "fiscal_documents");

            migrationBuilder.DeleteData(
                table: "fiscal_settings",
                keyColumn: "id",
                keyValue: 2);

            migrationBuilder.DropColumn(
                name: "company",
                table: "fiscal_settings");

            migrationBuilder.DropColumn(
                name: "issuer_id",
                table: "fiscal_inutilizations");

            migrationBuilder.DropColumn(
                name: "issuer_id",
                table: "fiscal_documents");

            migrationBuilder.CreateIndex(
                name: "ix_fiscal_inutilizations_series_from_number_to_number",
                table: "fiscal_inutilizations",
                columns: new[] { "series", "from_number", "to_number" });

            migrationBuilder.CreateIndex(
                name: "ix_fiscal_documents_series_number",
                table: "fiscal_documents",
                columns: new[] { "series", "number" },
                unique: true);
        }
    }
}
