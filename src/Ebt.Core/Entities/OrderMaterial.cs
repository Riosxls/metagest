namespace Ebt.Core.Entities;

/// <summary>
/// The material specification a customer's old orders gave for a product ("BK DIN 2393"): reference data read from the legacy internal sales order sheets, used
/// to fill the "Especificação do material" of a new order that carries none. Never wiped by the data reset.
/// </summary>
public class OrderMaterial
{
    public int Id { get; set; }
    public int CustomerId { get; set; }
    public Customer? Customer { get; set; }
    public required string ProductCode { get; set; }
    /// <summary>The material the old orders gave; null when they gave none (the row then only says the customer bought the product before).</summary>
    public string? Material { get; set; }
    /// <summary>How many old orders said this.</summary>
    public int Orders { get; set; }
    /// <summary>The observation these orders usually carried ("ISENTO DE OLEO E GRAXA", "Tratamento termico 30 HRB"). ProductCode "*" holds the one that goes on almost every order of the customer.</summary>
    public string? Note { get; set; }
    public DateOnly LastDate { get; set; }
}
